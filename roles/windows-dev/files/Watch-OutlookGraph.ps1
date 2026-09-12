<#
.SYNOPSIS
  Poll Microsoft Graph for Outlook mail, POST each message to a webhook (n8n),
  then apply the returned high-level commands to Graph (labels, move, delete, etc.).

.DESCRIPTION
  Local watcher for Outlook via Microsoft Graph.

  Flow:
    1. Resolve your signed-in Graph user (PowerShell rejects -UserId 'me').
    2. Read/write a small state file so the watermark advances between runs.
    3. Fetch messages in the chosen folder newer than the watermark.
    4. POST each message as JSON to -WebhookUrl (skipped in -DryRun).
    5. Run a Command dispatcher: each n8n action is adapted into Graph calls.

  First run WITHOUT -Since only seeds the watermark (does not blast history
  at your webhook). Pass -Since once to rewind/catch up from that moment, then
  OMIT -Since on later runs so the watermark advances. Passing -Since every
  time keeps rewinding to the same date. Omit -Once to process the backlog in
  repeated batches and then keep monitoring; use -Once for one batch and stop.

  n8n must answer the same HTTP request with JSON (Respond to Webhook).
  It should NOT send raw Graph payloads - only high-level commands.

  Flat response example (any field optional):
    {
      "categories": ["AI/Urgent"],
      "addCategories": ["AI/Billing"],
      "removeCategories": ["AI/NeedsReview"],
      "moveTo": "archive",
      "delete": false,
      "markRead": true,
      "skip": false
    }

  Explicit command batch:
    {
      "commands": [
        { "action": "addCategories", "value": ["AI/Urgent"] },
        { "action": "moveTo", "value": "archive" }
      ]
    }

  Supported actions: skip, categories, addCategories, removeCategories,
  markRead, moveTo, delete.

  moveTo accepts: archive, deleteditems, inbox, drafts, sentitems, junkemail,
  a folder display name, or a folder id.

.PARAMETER WebhookUrl
  HTTPS URL of your n8n Webhook node (Production or Test URL).
  Required unless you pass -DryRun.

.PARAMETER StatePath
  Path to the JSON watermark / processed-id file.
  Default: outlook-monitor.state.json next to this script.

.PARAMETER Folder
  Mail folder to watch. Default: Inbox.
  Also accepts well-known names (Archive, DeletedItems, ...) or a folder id.

.PARAMETER Since
  One-shot rewind / catch-up start. Sets the watermark to this datetime and
  clears processed ids, e.g. -Since '2026-09-01'. Local times convert to UTC.

  IMPORTANT: use -Since only when you want to START (or RESTART) from that
  date. After that first run, DROP -Since on later invocations so the saved
  watermark can advance:
    1st:  .\Watch-OutlookGraph.ps1 -DryRun -Once -Since '2026-09-01'
    next: .\Watch-OutlookGraph.ps1 -DryRun -Once

  Passing -Since again every time rewinds to that date and you will keep
  seeing the same first batch. To replay mail on purpose, pass -Since again
  or delete outlook-monitor.state.json.

.PARAMETER PollSeconds
  Seconds to sleep between poll cycles when NOT using -Once. Default: 30.
  Minimum 5, maximum 3600.

.PARAMETER Scopes
  Graph OAuth scopes used if Connect-MgGraph is needed. Default: Mail.ReadWrite.

.PARAMETER BatchLimit
  Max messages fetched/processed per poll cycle. Default: 25.
  Raise this (e.g. 200) for a larger catch-up in one -Once run, or run
  repeatedly so each cycle takes the next batch after the watermark advances.


.PARAMETER IncludeBody
  Include the full message body (HTML/text) in the webhook JSON.
  Default is bodyPreview only (smaller payloads).

.PARAMETER DryRun
  Debug mode: connect to Graph, list matching messages, print the JSON payload
  that WOULD be posted. Does not call the webhook and does not mutate mail
  (no categories/move/delete). WebhookUrl is not required.
  Still advances the watermark so a later -Once run shows the next batch.

.PARAMETER Once
  Run a single poll cycle and exit.
  Without -Once the script loops forever (sleeping -PollSeconds between cycles).
  Continuous mode walks ALL mail newer than the watermark in repeated batches
  of -BatchLimit, then keeps watching for new mail until you Ctrl+C.
  Example: -Since '2026-09-01' with no -Once eventually drains everything since
  that date, then idles on new arrivals. -Once means one batch then stop.
  Use -Since with -Once only when you want a single catch-up batch.

.EXAMPLE
  # Start a dry-run catch-up from Sept 1 (sets watermark ONCE)
  .\Watch-OutlookGraph.ps1 -DryRun -Once -Since '2026-09-01'

.EXAMPLE
  # Continue forward from saved watermark (omit -Since)
  .\Watch-OutlookGraph.ps1 -DryRun -Once

.EXAMPLE
  # Larger first catch-up batch, then continue without -Since
  .\Watch-OutlookGraph.ps1 -DryRun -Once -Since '2026-09-01' -BatchLimit 200
  .\Watch-OutlookGraph.ps1 -DryRun -Once -BatchLimit 200

.EXAMPLE
  # Live monitor -> n8n (loops forever)
  .\Watch-OutlookGraph.ps1 -WebhookUrl 'https://n8n.example/webhook/outlook-in'

.EXAMPLE
  # Catch up from a date then keep watching (no -Once = continuous batches)
  .\Watch-OutlookGraph.ps1 -WebhookUrl 'https://n8n.example/webhook/outlook-in' -Since '2026-09-01'

.EXAMPLE
  # Live catch-up from a date, one cycle, include full body
  .\Watch-OutlookGraph.ps1 -WebhookUrl 'https://n8n.example/webhook/outlook-in' -Once -Since '2026-09-01' -IncludeBody -BatchLimit 100

.NOTES
  Requires Microsoft.Graph.Mail (or Microsoft.Graph) and a Graph sign-in
  with Mail.ReadWrite (Connect-MgGraph).
  Prefer Get-Help .\Watch-OutlookGraph.ps1 -Full over inventing -Help.
#>

[CmdletBinding()]
param(
    # Required unless -DryRun (for local debugging without n8n)
    [string]$WebhookUrl,

    [string]$StatePath = (Join-Path $PSScriptRoot 'outlook-monitor.state.json'),

    [string]$Folder = 'Inbox',

    # Rewind / set watermark: process mail newer than this moment
    [datetime]$Since,

    [ValidateRange(5, 3600)]
    [int]$PollSeconds = 30,

    [string[]]$Scopes = @('Mail.ReadWrite'),

    [int]$BatchLimit = 25,

    [switch]$IncludeBody,

    # List matching mail + print webhook payload; no POST, no Graph mutations
    [switch]$DryRun,

    [switch]$Once
)

$ErrorActionPreference = 'Stop'

if (-not $DryRun -and [string]::IsNullOrWhiteSpace($WebhookUrl)) {
    throw 'WebhookUrl is required unless you pass -DryRun.'
}

# --- Graph connection / identity ---------------------------------------------

function Ensure-GraphConnection {
    try {
        $ctx = Get-MgContext -ErrorAction Stop
        if (-not $ctx) { throw 'No context' }
    }
    catch {
        Write-Host 'Connecting to Microsoft Graph...'
        Connect-MgGraph -Scopes $Scopes | Out-Null
    }
}

function Get-GraphUserId {
    # Graph PowerShell rejects -UserId 'me'. Resolve the signed-in user once.
    $me = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName,displayName'
    if (-not $me.id) { throw 'Could not resolve signed-in Graph user id.' }
    Write-Host ("Signed in as {0} ({1})" -f $me.userPrincipalName, $me.id)
    return [string]$me.id
}

function Read-State {
    if (Test-Path -LiteralPath $StatePath) {
        return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    }
    return [pscustomobject]@{
        lastSeenReceivedDateTime = $null
        processedIds             = @()
    }
}

function Write-State($state) {
    $ids = @($state.processedIds | Select-Object -Last 500)
    $out = [pscustomobject]@{
        lastSeenReceivedDateTime = $state.lastSeenReceivedDateTime
        processedIds             = $ids
    }
    $dir = Split-Path -Parent $StatePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $out | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Set-WatermarkFromSince([datetime]$sinceValue, $state) {
    $iso = $sinceValue.ToUniversalTime().ToString('o')
    $state.lastSeenReceivedDateTime = $iso
    # Clear processed ids so mail after -Since can be posted even if seen before
    $state.processedIds = @()
    Write-State $state
    Write-Host "Watermark set to $iso (-Since). Next runs: omit -Since so this advances."
    return $state
}

function Get-MailFolderId([string]$displayName) {
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        throw 'Folder name/id is empty.'
    }
    if ($displayName -match '^[0-9a-fA-F-]{20,}$' -or $displayName -like 'AAMk*') {
        return $displayName
    }

    $wellKnown = @{
        'inbox'        = 'inbox'
        'archive'      = 'archive'
        'deleteditems' = 'deleteditems'
        'deleted'      = 'deleteditems'
        'drafts'       = 'drafts'
        'sentitems'    = 'sentitems'
        'junkemail'    = 'junkemail'
    }
    $key = $displayName.ToLowerInvariant()
    if ($wellKnown.ContainsKey($key)) {
        # Well-known folder names work as MailFolderId with a real UserId
        $folder = Get-MgUserMailFolder -UserId $script:UserId -MailFolderId $wellKnown[$key]
        if (-not $folder -or -not $folder.Id) {
            throw "Could not resolve well-known folder: $displayName"
        }
        return $folder.Id
    }

    $escaped = $displayName.Replace("'", "''")
    $folders = Get-MgUserMailFolder -UserId $script:UserId -Filter "displayName eq '$escaped'" -All
    $match = $folders | Select-Object -First 1
    if (-not $match) { throw "Mail folder not found: $displayName" }
    return $match.Id
}

# --- Command handlers (Adapter: n8n action -> Graph) -------------------------

function Invoke-CmdSkip {
    param($Message, $Value)
    Write-Host "  skip: $($Message.Subject)"
    return @{ stop = $true }
}

function Invoke-CmdSetCategories {
    param($Message, $Value)
    $cats = @($Value | ForEach-Object { [string]$_ })
    Update-MgUserMessage -UserId $script:UserId -MessageId $Message.Id -BodyParameter @{ categories = $cats } | Out-Null
    Write-Host "  categories = $($cats -join ', ')"
}

function Invoke-CmdAddCategories {
    param($Message, $Value)
    $cats = [System.Collections.Generic.List[string]]::new()
    foreach ($c in @($Message.Categories)) { [void]$cats.Add([string]$c) }
    foreach ($c in @($Value)) {
        if ($c -and -not $cats.Contains([string]$c)) { [void]$cats.Add([string]$c) }
    }
    Update-MgUserMessage -UserId $script:UserId -MessageId $Message.Id -BodyParameter @{ categories = @($cats) } | Out-Null
    Write-Host "  addCategories: $($Value -join ', ')"
}

function Invoke-CmdRemoveCategories {
    param($Message, $Value)
    $cats = [System.Collections.Generic.List[string]]::new()
    foreach ($c in @($Message.Categories)) { [void]$cats.Add([string]$c) }
    foreach ($c in @($Value)) { [void]$cats.Remove([string]$c) }
    Update-MgUserMessage -UserId $script:UserId -MessageId $Message.Id -BodyParameter @{ categories = @($cats) } | Out-Null
    Write-Host "  removeCategories: $($Value -join ', ')"
}

function Invoke-CmdMarkRead {
    param($Message, $Value)
    Update-MgUserMessage -UserId $script:UserId -MessageId $Message.Id -BodyParameter @{ isRead = [bool]$Value } | Out-Null
    Write-Host "  markRead = $Value"
}

function Invoke-CmdMoveTo {
    param($Message, $Value)
    $destId = Get-MailFolderId ([string]$Value)
    Move-MgUserMessage -UserId $script:UserId -MessageId $Message.Id -DestinationId $destId | Out-Null
    Write-Host "  moveTo: $Value"
}

function Invoke-CmdDelete {
    param($Message, $Value)
    if ($Value -eq $false) { return }
    Remove-MgUserMessage -UserId $script:UserId -MessageId $Message.Id
    Write-Host '  deleted'
    return @{ stop = $true }
}

# action name -> handler (Command dispatcher registry)
$script:CommandHandlers = @{
    skip             = ${function:Invoke-CmdSkip}
    categories       = ${function:Invoke-CmdSetCategories}
    addCategories    = ${function:Invoke-CmdAddCategories}
    removeCategories = ${function:Invoke-CmdRemoveCategories}
    markRead         = ${function:Invoke-CmdMarkRead}
    moveTo           = ${function:Invoke-CmdMoveTo}
    delete           = ${function:Invoke-CmdDelete}
}

function ConvertTo-CommandList($actions) {
    if (-not $actions) { return @() }

    # Explicit batch: { commands: [ { action, value }, ... ] }
    if ($actions.commands) {
        return @($actions.commands | ForEach-Object {
                [pscustomobject]@{ action = [string]$_.action; value = $_.value }
            })
    }

    # Flat object form - preserve a stable execution order
    $order = @('skip', 'categories', 'addCategories', 'removeCategories', 'markRead', 'moveTo', 'delete')
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $order) {
        $prop = $actions.PSObject.Properties[$name]
        if ($prop) {
            [void]$list.Add([pscustomobject]@{ action = $name; value = $prop.Value })
        }
    }
    return @($list)
}

function Invoke-CommandDispatcher {
    param($Message, $Actions)

    foreach ($cmd in (ConvertTo-CommandList $Actions)) {
        $handler = $script:CommandHandlers[$cmd.action]
        if (-not $handler) {
            Write-Warning "Unknown command '$($cmd.action)' - ignored"
            continue
        }
        $result = & $handler -Message $Message -Value $cmd.value
        if ($result -and $result.stop) { break }
    }
}

# --- Mail fetch / webhook -----------------------------------------------------

function Get-NewMessages($folderId, $state) {
    $select = 'id,subject,from,toRecipients,ccRecipients,receivedDateTime,isRead,categories,conversationId,internetMessageId,hasAttachments,bodyPreview,importance,flag'
    if ($IncludeBody) { $select += ',body' }

    $params = @{
        UserId       = $script:UserId
        MailFolderId = $folderId
        Top          = $BatchLimit
        Orderby      = 'receivedDateTime asc'
        Property     = $select.Split(',')
    }

    if ($state.lastSeenReceivedDateTime) {
        $since = ([datetime]$state.lastSeenReceivedDateTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $params['Filter'] = "receivedDateTime gt $since"
    }

    try {
        $messages = @(Get-MgUserMailFolderMessage @params)
    }
    catch {
        $params.Remove('Orderby')
        $messages = @(Get-MgUserMailFolderMessage @params)
        $messages = @($messages | Sort-Object ReceivedDateTime)
    }

    $known = [System.Collections.Generic.HashSet[string]]::new([string[]]@($state.processedIds))
    return @($messages | Where-Object { -not $known.Contains($_.Id) })
}

function Convert-MessageToPayload($msg) {
    $fromName = $null
    $fromAddr = $null
    if ($msg.From -and $msg.From.EmailAddress) {
        $fromName = $msg.From.EmailAddress.Name
        $fromAddr = $msg.From.EmailAddress.Address
    }

    $payload = [ordered]@{
        id                = $msg.Id
        internetMessageId = $msg.InternetMessageId
        conversationId    = $msg.ConversationId
        subject           = $msg.Subject
        receivedDateTime  = $msg.ReceivedDateTime
        isRead            = $msg.IsRead
        importance        = $msg.Importance
        hasAttachments    = $msg.HasAttachments
        categories        = @($msg.Categories)
        bodyPreview       = $msg.BodyPreview
        from              = @{
            name    = $fromName
            address = $fromAddr
        }
        to = @($msg.ToRecipients | ForEach-Object {
                @{ name = $_.EmailAddress.Name; address = $_.EmailAddress.Address }
            })
        cc = @($msg.CcRecipients | ForEach-Object {
                @{ name = $_.EmailAddress.Name; address = $_.EmailAddress.Address }
            })
    }
    if ($IncludeBody -and $msg.Body) {
        $payload.body = @{
            contentType = $msg.Body.ContentType
            content     = $msg.Body.Content
        }
    }
    return $payload
}

function Invoke-Webhook($payload) {
    $json = $payload | ConvertTo-Json -Depth 10 -Compress
    Invoke-RestMethod -Method Post -Uri $WebhookUrl -Body $json -ContentType 'application/json' -TimeoutSec 120
}

function Process-Cycle($folderId, $state) {
    # No watermark yet and no -Since: seed only (do not flood webhook with history)
    if (-not $state.lastSeenReceivedDateTime) {
        $latest = @(Get-MgUserMailFolderMessage -UserId $script:UserId -MailFolderId $folderId -Top 1 -Orderby 'receivedDateTime desc' -Property @('id','receivedDateTime'))
        if ($latest.Count -gt 0) {
            $state.lastSeenReceivedDateTime = $latest[0].ReceivedDateTime.ToUniversalTime().ToString('o')
            $state.processedIds = @($latest[0].Id)
            Write-State $state
            Write-Host "Seeded at $($state.lastSeenReceivedDateTime) (no history posted). Pass -Since to catch up."
        }
        return $state
    }

    $newMessages = Get-NewMessages -folderId $folderId -state $state

    foreach ($msg in $newMessages) {
        Write-Host ("New: {0} - {1}" -f $msg.ReceivedDateTime, $msg.Subject)
        try {
            $payload = Convert-MessageToPayload $msg
            if ($DryRun) {
                Write-Host '  [DryRun] webhook payload:'
                $payload | ConvertTo-Json -Depth 10 | Write-Host
            }
            else {
                $actions = Invoke-Webhook $payload
                Invoke-CommandDispatcher -Message $msg -Actions $actions
            }
        }
        catch {
            Write-Warning "Failed processing $($msg.Id): $_"
            continue
        }

        $state.processedIds = @($state.processedIds + $msg.Id)
        $msgTime = $msg.ReceivedDateTime.ToUniversalTime().ToString('o')
        if (-not $state.lastSeenReceivedDateTime -or $msgTime -gt $state.lastSeenReceivedDateTime) {
            $state.lastSeenReceivedDateTime = $msgTime
        }
        Write-State $state
    }

    if (-not $newMessages -or $newMessages.Count -eq 0) {
        Write-Host "$(Get-Date -Format o) - no new messages"
    }
    else {
        Write-Host ("Processed {0} message(s) this cycle." -f $newMessages.Count)
    }
    return $state
}

# --- main ---------------------------------------------------------------------

Ensure-GraphConnection
$script:UserId = Get-GraphUserId
$folderId = Get-MailFolderId $Folder
$state = Read-State

if ($PSBoundParameters.ContainsKey('Since')) {
    $state = Set-WatermarkFromSince -sinceValue $Since -state $state
}

if ($DryRun) {
    Write-Host "DryRun: listing mail / printing payloads only (no webhook, no Graph writes)"
}
else {
    Write-Host "Watching folder '$Folder' every ${PollSeconds}s"
    Write-Host "Webhook: $WebhookUrl"
}
Write-Host "State:   $StatePath"
if ($state.lastSeenReceivedDateTime) {
    Write-Host "Since:   $($state.lastSeenReceivedDateTime)"
}

do {
    try {
        $state = Process-Cycle -folderId $folderId -state $state
    }
    catch {
        Write-Warning "Poll cycle error: $_"
    }
    if (-not $Once) { Start-Sleep -Seconds $PollSeconds }
} while (-not $Once)
