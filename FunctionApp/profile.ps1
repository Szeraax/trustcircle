# Azure Functions profile.ps1
#
# This profile.ps1 will get executed every "cold start" of your Function App.
# "cold start" occurs when:
#
# * A Function App starts up for the very first time
# * A Function App starts up after being de-allocated due to inactivity
#
# You can define helper functions, run commands, or specify environment variables
# NOTE: any variables defined that are not environment variables will get reset after the first execution

# Authenticate with Azure PowerShell using MSI.
# Remove this if you are not planning on using MSI or Azure PowerShell.
# if ($env:MSI_SECRET) {
#     Disable-AzContextAutosave -Scope Process | Out-Null
#     Connect-AzAccount -Identity
# }

# Uncomment the next line to enable legacy AzureRm alias in Azure PowerShell.
# Enable-AzureRmAlias

# You can also define functions or aliases that can be referenced in any of your PowerShell functions.

function Assert-Signature {
    $appID = $Request.Body.application_id
    $publicKey = (Get-Item env:\APPID_PUBLICKEY_$appid -ea silent).value

    if (-not $appid -or -not $publicKey) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
            })
        throw
    }

    if (-not $Request.Headers."x-signature-timestamp" -or -not $Request.Headers."x-signature-ed25519") {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::Unauthorized
            })
        throw
    }

    [string]$message = $Request.Headers."x-signature-timestamp" + $Request.RawBody


    [byte[]]$public_bytes = $publicKey -replace "(..)", '0x$1|' -split "\|" | Where-Object { $_ }
    [byte[]]$message_bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    [byte[]]$signature_bytes = $Request.Headers."x-signature-ed25519" -replace "(..)", '0x$1|' -split "\|" | Where-Object { $_ }


    $result = [ASodium.SodiumPublicKeyAuth]::VerifyDetached(
        $signature_bytes,
        $message_bytes,
        $public_bytes
    )

    if ($result -eq $false) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::Unauthorized
            })
        throw
    }
    Write-Host "Signature is valid"
}

function Invoke-SqlQuery {
    [cmdletbinding(SupportsShouldProcess)]
    Param(
        [Parameter(ValueFromPipeline)]
        $Query,
        $SqlParameters,
        $ConnectionTimeout = 30,
        $QueryTimeout = 4
    )
    begin {
        if (
            $ENV:APP_DB_INSTANCE -and
            $ENV:APP_DB_DATABASE -and
            $ENV:APP_DB_USERNAME -and
            $ENV:APP_DB_PASSWORD
        ) {}
        else { throw "No info!" }

        $splat = @{
            ServerInstance    = $ENV:APP_DB_INSTANCE
            Database          = $ENV:APP_DB_DATABASE
            Credential        = (
                New-Object PSCredential -ArgumentList $ENV:APP_DB_USERNAME,
            (ConvertTo-SecureString -AsPlainText -Force $ENV:APP_DB_PASSWORD)
            )
            ConnectionTimeout = $ConnectionTimeout
            QueryTimeout      = $QueryTimeout
        }
        if ($SqlParameters) { $splat.Add('SqlParameters', $SqlParameters) }
    }

    process {
        if ($pscmdlet.ShouldProcess($splat.Database, $Query)) {
            if ($ENV:ENV_DEBUG -eq "1") { $Query -replace "`r?`n\s*", " " | Write-Host }

            # not datatable row objects due to [System.DBNull]::Value behavior
            if ($Query -match "^\s*SELECT") { $splat.Add("as", "PSObject") }

            $Attempt = 0
            $Completed = $false
            do {
                $Attempt++
                try {
                    Invoke-Sqlcmd2 @splat -Query $Query -ErrorAction Stop
                    $Completed = $true
                }
                catch {
                    if ($Attempt -gt 3) {
                        throw $_
                    }
                    else { Start-Sleep 3 }
                }
            } until ($Completed)
        }
    }
}

function Send-WebhookMessage {
    param(
        $Message,
        $Username,
        $Envelope = @{
            # type    = 4
            content = $message
        },
        $Uri
    )

    if ($username) {
        $envelope.username = $username
    }
    $cooked = $envelope | ConvertTo-Json -Compress
    if ($ENV:ENV_DEBUG -eq 1) {
        $invokeRestMethod_splat.Uri | Write-Host
        "cooked: $cooked" | Write-Host
    }

    if ($uri -as [uri] | Where-Object Scheme -EQ 'https') {}
    else {
        Write-Warning "No valid https uri in $uri. Skipping webhook."
        return
    }

    $invokeRestMethod_splat = @{
        Uri               = $uri
        Method            = "Post"
        ContentType       = "application/json"
        Body              = $cooked
        MaximumRetryCount = 5
        RetryIntervalSec  = 1
    }
    try { Invoke-RestMethod @invokeRestMethod_splat | Out-Null }
    catch {
        "failed" | Write-Host
        $invokeRestMethod_splat | ConvertTo-Json -Depth 3 -Compress
        $_
    }
}


function Set-SqlRow {
    [cmdletbinding(SupportsShouldProcess)]
    Param(
        [Parameter(Mandatory)]
        [hashtable]$Data,
        [Parameter(Mandatory)]
        $SqlTable,
        [Parameter(Mandatory)]
        $KeyField,
        [Parameter(Mandatory)]
        $KeyValue
    )
    begin {
    }

    process {
        # If I decide to enable ValueByPipeline, collect results into a list and upload in end{}
    }

    end {
        $Query = "UPDATE $SqlTable SET {0} WHERE $KeyField = '$KeyValue'" -f (($Data.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join ",")
        Invoke-SqlQuery -Query $Query
    }
}


function Export-SqlData {
    <#
    .SYNOPSIS
    This function will convert powershell objects into SQL compatible data rows

    .DESCRIPTION
    It uses the properties of the 1st item to enforce all objects in the array have an equal number of fields.
    It replaces an null properties with a DBNULL value (different from an empty string, of course!)

    .PARAMETER Data
    The array of objects to get written to the database

    .PARAMETER SqlTable
    The table in the database to get written to

    .PARAMETER PageSize
    How many objects to upload to the database at a time. Typically, 1000 is the max

    .EXAMPLE
    Export-SqlData ([PSCustomObject]@{a=2;b=$null;c=''},[PSCustomObject]@{a=3.14}) -WhatIf

    What if: Performing the operation "INSERT INTO $SqlTable (a,b,c) VALUES ('2',null,''),
    ('3.14',null,null)" on target "".
    #>
    [cmdletbinding(SupportsShouldProcess)]
    Param(
        [array]$Data,
        [Parameter(Mandatory)]
        $SqlTable,
        $OutputColumns,
        $PageSize = 900
    )
    begin {
        $select = $Data[0].PSObject.Properties.Name
        if ($PSBoundParameters.OutputColumns) {
            $output = "OUTPUT "
            $outputItems = $PSBoundParameters.OutputColumns | Where-Object { $_ } | ForEach-Object {
                "INSERTED.[$_]"
            }
            $output += $outputItems -join ", "
        }
        else {
            $output = ''
        }
    }

    process {
        # If I decide to enable ValueByPipeline, collect results into a list and upload in end{}
    }

    end {
        for ($i = 0; $i -lt $Data.Count; $i += $PageSize) {
            $Query = "INSERT INTO $SqlTable ([{0}]) $output VALUES ({1})" -f ($Data[0].PSObject.Properties.Name -join "],["),
            (($Data[$i..($i + $PageSize - 1)] | Select-Object $select | ForEach-Object {
                        ($_.PSObject.Properties.Value | & { process {
                            # nulls need converted to DBNULL, not empty strings
                            if ($null -eq $_) { 'null' }
                            else { "'{0}'" -f ($_ -replace "'", "''") }
                        } }) -join "," # Join each property in a single object
                }) -join "),`n(" ) # Join each object in a single page/call to db

            Invoke-SqlQuery -Query $Query
        }
    }
}

function Invoke-RequestProcessing {
    param(
        $body
    )

    $userCreationTime = Get-Date -UnixTimeSeconds ((($body.member.user.id -shr 22) + 1420070400000) / 1000)
    if (1 -eq $ENV:APP_DISABLE_ALTS -and $userCreationTime -gt (Get-Date).AddDays(-7)) {
        Send-Response -Message "Sorry, alts are currently disabled."
        return
    }

    $commandName = @(
        $body.data.name
        $body.data.options | Where-Object type -In 1, 2 | Select-Object -First 1 -expand name
        $body.data.options.options | Where-Object type -In 1, 2 | Select-Object -First 1 -expand name
    ) -join "_"
    Write-Host $commandName

    if ($existingGame = "Select top 1 * from game where
            guildId = '{0}'
            and EndTime > (SYSDATETIME())
            order by EndTime desc
            " -f $body.guild_id | Invoke-SqlQuery
    ) {
        Write-Host "Found existing game"
    }

    $body | ConvertTo-Json -Depth 10 -Compress | Write-Host
    switch ($commandName) {
        "admin_start_game" {

            if ($existingGame) {
                # TODO: Be able to update the end time or webhook by running start_game during an existing game
                $endTime = ([System.DateTimeOffset]$existingGame.EndTime).ToUnixTimeSeconds()
                $message = "Your server already has a game running with an end time <t:{0}:R> (at <t:{0}>)" -f $endtime
                Send-Response -Message $message
                return
            }
            else {
                $end = [System.DateTime]::Now.AddHours(72).ToUniversalTime()
                $data = @{
                    EndTime     = $end
                    GuildId     = $body.guild_id
                    InitiatorId = $body.member.user.id
                }

                if ($duration =
                    $body.Data.options
                    | Where-Object name -EQ "start"
                    | Select-Object -expand options
                    | Where-Object name -EQ "game"
                    | Select-Object -expand options
                    | Where-Object name -EQ 'end'
                    | Select-Object -expand Value
                ) {
                    $data.EndTime = [System.DateTime]::Now.AddHours($duration).ToUniversalTime()
                }
                if ($webhook =
                    $body.Data.options
                    | Where-Object name -EQ "start"
                    | Select-Object -expand options
                    | Where-Object name -EQ "game"
                    | Select-Object -expand options
                    | Where-Object name -EQ 'webhook'
                    | Select-Object -expand Value
                ) {
                    $data.StatusWebhook = $webhook
                }

                $existingGame = Export-SqlData -Data ([PSCustomObject]$data) -SqlTable Game -OutputColumns EndTime, StatusWebhook, Id
                "Update Game SET [Ruid] = '{0}{1}' where Id = '{0}'" -f @(
                    $existingGame.Id
                    Get-Random -Maximum 9gb -Minimum 1gb
                ) | Invoke-SqlQuery
                $endTime = ([System.DateTimeOffset]$existingGame.EndTime).ToUnixTimeSeconds()
                $message = "You now have a game running that ends <t:{0}:R> (at <t:{0}>)" -f $endtime
                Send-Response -Message $message

                $webhookMessage_params = @{
                    Message  = "Let the circle of trust begin!"
                    Username = "Game Maker"
                    Uri      = $existingGame.StatusWebhook
                }
                Send-WebhookMessage @webhookMessage_params

                return
            }
        }
        "admin_end_game" {
            if ($existingGame = "Select top 1 * from game where
            guildId = '{0}'
            and EndTime > (SYSDATETIME())
            and InitiatorId = '$($body.member.user.id)'
            " -f $body.guild_id | Invoke-SqlQuery) {
                "Update Game set EndTime = (SYSDATETIME()) where guildId = '{0}' and EndTime > (SYSDATETIME())" -f $body.guild_id | Invoke-SqlQuery
                $message = "Game ended"
                Send-Response -Message $message

                $webhookMessage_params = @{
                    Message  = "The circle of trust comes to a close (prematurely)!"
                    Username = "Game Maker"
                    Uri      = $existingGame.StatusWebhook
                }
                Send-WebhookMessage @webhookMessage_params
                return
            }
            elseif ($existingGame = "Select top 1 * from game where
            guildId = '{0}'
            and EndTime > (SYSDATETIME())
            " -f $body.guild_id | Invoke-SqlQuery) {
                $message = "You did not start the game. Please contact <@$($existingGame.InitiatorId)> and have them perform this action."
                Send-Response -Message $message

            }
            else {
                $message = "There is no currently running game."
                Send-Response -Message $message
                return
            }

        }

        "admin_change_circle" {
            if ($existingGame = "Select top 1 * from game where
            guildId = '{0}'
            and EndTime > (SYSDATETIME())
            and InitiatorId = '$($body.member.user.id)'
            " -f $body.guild_id | Invoke-SqlQuery) {

                $label = $body.Data.options
                | Where-Object name -EQ "change"
                | Select-Object -expand options
                | Where-Object name -EQ "circle"
                | Select-Object -expand options
                | Where-Object name -EQ 'label'
                | Select-Object -expand Value
                if ([string]::IsNullOrWhiteSpace($label)) {
                    $message = "No valid label text submitted"
                    Send-Response -Message $message
                    return
                }
                $new_label = $body.Data.options
                | Where-Object name -EQ "change"
                | Select-Object -expand options
                | Where-Object name -EQ "circle"
                | Select-Object -expand options
                | Where-Object name -EQ 'new_label'
                | Select-Object -expand Value
                if ([string]::IsNullOrWhiteSpace($new_label)) {
                    $message = "No valid new_label text submitted"
                    Send-Response -Message $message
                    return
                }

                "UPDATE player set Label = @new_label where game = $($existingGame.Id) and Label = @label" -f $body.guild_id | Invoke-SqlQuery -SqlParameters @{
                    label     = $label
                    new_label = $new_label
                }

                $message = "``$label`` circle updated to ``$new_label``"
                Send-Response -Message $message

                $webhookMessage_params = @{
                    Message  = "A circle has been administratively changed to ``$new_label``!"
                    Username = "Game Maker"
                    Uri      = $existingGame.StatusWebhook
                }
                Send-WebhookMessage @webhookMessage_params
                return
            }
            elseif ($existingGame = "Select top 1 * from game where
            guildId = '{0}'
            and EndTime > (SYSDATETIME())
            " -f $body.guild_id | Invoke-SqlQuery) {
                $message = "You did not start the game. Please contact <@$($existingGame.InitiatorId)> and have them perform this action."
                Send-Response -Message $message
            }
            else {
                $message = "There is no currently running game."
                Send-Response -Message $message
                return
            }
        }

        "admin_delete_circle" {
            if ($existingGame = "Select top 1 * from game where
            guildId = '{0}'
            and EndTime > (SYSDATETIME())
            and InitiatorId = '$($body.member.user.id)'
            " -f $body.guild_id | Invoke-SqlQuery) {

                $label = $body.Data.options
                | Where-Object name -EQ "delete"
                | Select-Object -expand options
                | Where-Object name -EQ "circle"
                | Select-Object -expand options
                | Where-Object name -EQ 'label'
                | Select-Object -expand Value
                if ([string]::IsNullOrWhiteSpace($label)) {
                    $message = "No valid label text submitted"
                    Send-Response -Message $message
                    return
                }

                "delete from player where game = $($existingGame.Id) and Label = @label" -f $body.guild_id | Invoke-SqlQuery -SqlParameters @{
                    label = $label
                }

                $message = "``$label`` circle deleted"
                Send-Response -Message $message

                $webhookMessage_params = @{
                    Message  = "A circle was administratively deleted"
                    Username = "Game Maker"
                    Uri      = $existingGame.StatusWebhook
                }
                # Send-WebhookMessage @webhookMessage_params
                return
            }
            elseif ($existingGame = "Select top 1 * from game where
            guildId = '{0}'
            and EndTime > (SYSDATETIME())
            " -f $body.guild_id | Invoke-SqlQuery) {
                $message = "You did not start the game. Please contact <@$($existingGame.InitiatorId)> and have them perform this action."
                Send-Response -Message $message
            }
            else {
                $message = "There is no currently running game."
                Send-Response -Message $message
                return
            }
        }

        "create_circle" {
            if (-not $existingGame) {
                $message = 'No existing game found. Run `/start game` to begin a game.'
                Send-Response -Message $message
                return
            }
            $circle = "select top 1 * from Player where
            Game = '$($existingGame.Id)'
            AND UserId = '$($body.member.user.id)'
            " | Invoke-SqlQuery

            if ($circle) {
                $message = 'You have already created a circle. Its label is `{0}` and has key `{1}` (it currently has {2} {3}).' -f @(
                    $circle.Label
                    $circle.Key
                    $circle.Count
                    $circle.Count -gt 1 ? "members":"member"
                )
                Send-Response -Message $message
                return
            }
            else {
                $verbs = @(
                    "abiding", "accelerating", "accepting", "accomplishing", "achieving", "acquiring",
                    "acceding", "activating", "adapting", "adding", "addressing", "administering",
                    "admiring", "admitting", "adopting", "advising", "affording", "agreeing",
                    "alerting", "alighting", "allowing", "altering", "amusing", "analyzing",
                    "announcing", "annoying", "answering", "anticipating", "apologizing", "appearing",
                    "applauding", "applauding", "appointing", "appraising", "appreciating", "approving",
                    "arbitrating", "arguing", "arising", "arranging", "arresting", "arriving",
                    "ascertaining", "asking", "assembling", "assessing", "assisting", "assuring",
                    "attaching", "attacking", "attaining", "attempting", "attending", "attracting",
                    "auditing", "avoiding", "awaking", "backing", "baking", "balancing",
                    "banning", "banging", "barring", "bating", "bathing", "battling",
                    "being", "beaming", "bearing", "beating", "becoming", "begging",
                    "beginning", "behaving", "beholding", "belonging", "bending", "besetting",
                    "betting", "biding", "binding", "biting", "bleaching", "bleeding",
                    "blessing", "blinding", "blinking", "blotting", "blowing", "blushing",
                    "boasting", "boiling", "bolting", "bombing", "booking", "boring",
                    "borrowing", "bouncing", "bowing", "boxing", "braking", "branching",
                    "breaking", "breathing", "breeding", "briefing", "bringing", "broadcasting",
                    "bruising", "brushing", "bubbling", "budgeting", "building", "bumping",
                    "burning", "bursting", "burying", "busting", "buying", "buzzing",
                    "calculating", "calling", "camping", "caring", "carrying", "carving",
                    "casting", "cataloging", "catching", "causing", "challenging", "changing",
                    "charging", "charting", "chasing", "cheating", "checking", "cheering",
                    "chewing", "choking", "choosing", "chopping", "claiming", "clapping",
                    "clarifying", "classifying", "cleaning", "clearing", "clinging", "clipping",
                    "closing", "clothing", "coaching", "coiling", "collecting", "coloring",
                    "combing", "coming", "commanding", "communicating", "comparing", "competing",
                    "compiling", "complaining", "completing", "composing", "computing", "conceiving",
                    "concentrating", "conceptualizing", "concerning", "concluding", "conducting", "confessing",
                    "confronting", "confusing", "connecting", "conserving", "considering", "consisting",
                    "consolidating", "constructing", "consulting", "containing", "continuing", "contracting",
                    "controlling", "converting", "coordinating", "copying", "correcting", "correlating",
                    "costing", "coughing", "counseling", "counting", "covering", "cracking",
                    "crashing", "crawling", "creating", "creeping", "critiquing", "crossing",
                    "crushing", "crying", "curing", "curling", "curving", "cutting",
                    "cycling", "damming", "damaging", "dancing", "daring", "dealing",
                    "decaying", "deceiving", "deciding", "decorating", "defining", "delaying",
                    "delegating", "delighting", "delivering", "demonstrating", "depending", "describing",
                    "deserting", "deserving", "designing", "destroying", "detailing", "detecting",
                    "determining", "developing", "devising", "diagnosing", "digging", "directing",
                    "disagreeing", "disappearing", "disapproving", "disarming", "discovering", "disliking",
                    "dispensing", "displaying", "disproving", "dissecting", "distributing", "diving",
                    "diverting", "dividing", "doing", "doubling", "doubting", "drafting",
                    "dragging", "draining", "dramatizing", "drawing", "dreaming", "dressing",
                    "drinking", "dripping", "driving", "dropping", "drowning", "drumming",
                    "drying", "dusting", "dwelling", "earning", "eating", "editing",
                    "educating", "eliminating", "embarrassing", "employing", "emptying", "enacting",
                    "encouraging", "ending", "enduring", "enforcing", "engineering", "enhancing",
                    "enjoying", "enlisting", "ensuring", "entering", "entertaining", "escaping",
                    "establishing", "estimating", "evaluating", "examining", "exceeding", "exciting",
                    "excusing", "executing", "exercising", "exhibiting", "existing", "expanding",
                    "expecting", "expediting", "experimenting", "explaining", "exploding", "expressing",
                    "extending", "extracting", "facing", "facilitating", "fading", "failing",
                    "fancying", "fastening", "faxing", "fearing", "feeding", "feeling",
                    "fencing", "fetching", "fighting", "filling", "filling", "filming",
                    "finalizing", "financing", "finding", "firing", "fitting", "fixing",
                    "flapping", "flashing", "fleeing", "flinging", "floating", "flooding",
                    "flowing", "flowering", "flying", "folding", "following", "fooling",
                    "forbidding", "forcing", "forecasting", "foregoing", "foreseeing", "foretelling",
                    "forgetting", "forgiving", "forming", "formulating", "forsaking", "framing",
                    "freezing", "frightening", "frying", "gathering", "gazing", "generating",
                    "getting", "giving", "glowing", "glueing", "going", "governing",
                    "grabbing", "graduating", "grating", "greasing", "greeting", "grinning",
                    "grinding", "griping", "groaning", "growing", "guaranteeing", "guarding",
                    "guessing", "guiding", "hammering", "handing", "handling", "handwriting",
                    "hanging", "happening", "harassing", "harming", "hating", "haunting",
                    "heading", "healing", "heaping", "hearing", "heating", "helping",
                    "hiding", "hitting", "holding", "hooking", "hoping", "hoping",
                    "hovering", "hugging", "humming", "hunting", "hurrying", "hurting",
                    "hypothesizing", "identifying", "ignoring", "illustrating", "imagining", "implementing",
                    "impressing", "improving", "improvising", "including", "increasing", "inducing",
                    "influencing", "informing", "initiating", "injecting", "injuring", "inlaying",
                    "innovating", "inputing", "inspecting", "inspiring", "installing", "instituting",
                    "instructing", "insuring", "integrating", "intending", "intensifying", "interesting",
                    "interfering", "interlaying", "interpreting", "interrupting", "interviewing", "introducing",
                    "inventing", "inventorying", "investigating", "inviting", "irritating", "itching",
                    "jailing", "jamming", "jogging", "joining", "joking", "judging",
                    "juggling", "jumping", "justifying", "keeping", "keeping", "kicking",
                    "killing", "kissing", "kneeling", "knitting", "knocking", "knotting",
                    "knowing", "labeling", "landing", "lasting", "laughing", "launching",
                    "laying", "leading", "leaning", "leaping", "learning", "leaving",
                    "lecturing", "lending", "letting", "leveling", "licensing", "licking",
                    "lying", "lifting", "lighting", "lightening", "liking", "listing",
                    "listening", "living", "loading", "locating", "locking", "logging",
                    "longing", "looking", "losing", "loving", "maintaining", "making",
                    "manning", "managing", "manipulating", "manufacturing", "mapping", "marching",
                    "marking", "marketing", "marrying", "matching", "mating", "mattering",
                    "meaning", "measuring", "meddling", "mediating", "meeting", "melting",
                    "melting", "memorizing", "mending", "mentoring", "milking", "mining",
                    "misleading", "missing", "misspelling", "mistaking", "misunderstanding", "mixing",
                    "moaning", "modeling", "modifying", "monitoring", "mooring", "motivating",
                    "mourning", "moving", "mowing", "muddling", "mugging", "multiplying",
                    "murdering", "nailing", "naming", "navigating", "needing", "negotiating",
                    "nesting", "nodding", "nominating", "normalizing", "noting", "noticing",
                    "numbering", "obeying", "objecting", "observing", "obtaining", "occurring",
                    "offending", "offering", "officiating", "opening", "operating", "ordering",
                    "organizing", "orienteering", "originating", "overcoming", "overdoing", "overdrawing",
                    "overflowing", "overhearing", "overtaking", "overthrowing", "owing", "owning",
                    "packing", "paddling", "painting", "parking", "parting", "participating",
                    "passing", "pasting", "patting", "pausing", "paying", "pecking",
                    "pedaling", "peeling", "peeping", "perceiving", "perfecting", "performing",
                    "permitting", "persuading", "phoning", "photographing", "picking", "piloting",
                    "pinching", "pining", "pinpointing", "pioneering", "placing", "planing",
                    "planting", "playing", "pleading", "pleasing", "plugging", "pointing",
                    "poking", "polishing", "popping", "possessing", "posting", "pouring",
                    "practicing", "praising", "praying", "preaching", "preceding", "predicting",
                    "preferring", "preparing", "prescribing", "presenting", "preserving", "presetting",
                    "presiding", "pressing", "pretending", "preventing", "pricking", "printing",
                    "processing", "procuring", "producing", "professing", "programming", "progressing",
                    "projecting", "promising", "promoting", "proofreading", "proposing", "protecting",
                    "proving", "providing", "publicizing", "pulling", "pumping", "punching",
                    "puncturing", "punishing", "purchasing", "pushing", "putting", "qualifying",
                    "questioning", "queueing", "quitting", "racing", "radiating", "raining",
                    "raising", "ranking", "rating", "reaching", "reading", "realigning",
                    "realizing", "reasoning", "receiving", "recognizing", "recommending", "reconciling",
                    "recording", "recruiting", "reducing", "referring", "reflecting", "refusing",
                    "regretting", "regulating", "rehabilitating", "reigning", "reinforcing", "rejecting",
                    "rejoicing", "relating", "relaxing", "releasing", "relying", "remaining",
                    "remembering", "reminding", "removing", "rendering", "reorganizing", "repairing",
                    "repeating", "replacing", "replying", "reporting", "representing", "reproducing",
                    "requesting", "rescuing", "researching", "resolving", "responding", "restoring",
                    "restructuring", "retiring", "retrieving", "returning", "reviewing", "revising",
                    "rhyming", "riding", "riding", "ringing", "rinsing", "rising",
                    "risking", "robing", "rocking", "rolling", "rotting", "rubbing",
                    "ruining", "ruling", "running", "rushing", "sacking", "sailing",
                    "satisfying", "saving", "sawing", "saying", "scaring", "scattering",
                    "scheduling", "scolding", "scorching", "scraping", "scratching", "screaming",
                    "screwing", "scribbling", "scrubbing", "sealing", "searching", "securing",
                    "seeing", "seeking", "selecting", "selling", "sending", "sensing",
                    "separating", "serving", "servicing", "setting", "settling", "sewing",
                    "shading", "shaking", "shaping", "sharing", "shaving", "shearing",
                    "shedding", "sheltering", "shining", "shivering", "shocking", "shoeing",
                    "shooting", "shopping", "showing", "shrinking", "shrugging", "shutting",
                    "sighing", "signing", "signaling", "simplifying", "sining", "singing",
                    "sinking", "sipping", "siting", "sketching", "skiing", "skipping",
                    "slapping", "slaying", "sleeping", "sliding", "slinging", "slinking",
                    "slipping", "slitting", "slowing", "smashing", "smelling", "smiling",
                    "smiting", "smoking", "snatching", "sneaking", "sneezing", "sniffing",
                    "snoring", "snowing", "soaking", "solving", "soothing", "soothsaying",
                    "sorting", "sounding", "sowing", "sparing", "sparking", "sparkling",
                    "speaking", "specifying", "speeding", "spelling", "spending", "spilling",
                    "spinning", "spiting", "splitting", "spoiling", "spotting", "spraying",
                    "spreading", "springing", "sprouting", "squashing", "squeaking", "squealing",
                    "squeezing", "staining", "stamping", "standing", "staring", "starting",
                    "staying", "stealing", "steering", "stepping", "sticking", "stimulating",
                    "stinging", "stinking", "stirring", "stitching", "stoping", "storing",
                    "strapping", "streamlining", "strengthening", "stretching", "striding", "striking",
                    "stringing", "striping", "striving", "stroking", "structuring", "studying",
                    "stuffing", "subletting", "subtracting", "succeeding", "sucking", "suffering",
                    "suggesting", "suiting", "summarizing", "supervising", "supplying", "supporting",
                    "supposing", "surprising", "surrounding", "suspecting", "suspending", "swearing",
                    "sweating", "sweeping", "swelling", "swimming", "swinging", "switching",
                    "symbolizing", "synthesizing", "systemizing", "tabulating", "taking", "talking",
                    "taming", "taping", "targeting", "tasting", "teaching", "tearing",
                    "teasing", "telephoning", "telling", "tempting", "terrifying", "testing",
                    "thanking", "thawing", "thinking", "thriving", "throwing", "thrusting",
                    "ticking", "tickling", "tying", "timing", "tipping", "tiring",
                    "touching", "touring", "towing", "tracing", "trading", "training",
                    "transcribing", "transferring", "transforming", "translating", "transporting", "trapping",
                    "traveling", "treading", "treating", "trembling", "tricking", "tripping",
                    "trotting", "troubling", "troubleshooting", "trusting", "trying", "tugging",
                    "tumbling", "turning", "tutoring", "twisting", "typing", "undergoing",
                    "understanding", "undertaking", "undressing", "unfastening", "unifying", "uniting",
                    "unlocking", "unpacking", "untidying", "updating", "upgrading", "upholding",
                    "upsetting", "using", "utilizing", "vanishing", "verbalizing", "verifying",
                    "vexing", "visiting", "wailing", "waiting", "waking", "walking",
                    "wandering", "wanting", "warming", "warning", "washing", "wasting",
                    "watching", "watering", "waving", "wearing", "weaving", "wedding",
                    "weeping", "weighing", "welcoming", "wending", "wetting", "whining",
                    "whipping", "whirling", "whispering", "whistling", "wining", "winding",
                    "winking", "wiping", "wishing", "withdrawing", "withholding", "withstanding",
                    "wobbling", "wondering", "working", "worrying", "wrapping", "wrecking",
                    "wrestling", "wriggling", "wringing", "writing", "x-raying", "yawning",
                    "yelling", "zipping", "zooming"
                )
                $nouns = @(
                    "time", "year", "people", "way", "day", "man",
                    "thing", "woman", "life", "child", "world", "school",
                    "state", "family", "student", "group", "country", "problem",
                    "hand", "part", "place", "case", "week", "company",
                    "system", "program", "question", "work", "government", "number",
                    "night", "point", "home", "water", "room", "mother",
                    "area", "money", "story", "fact", "month", "right",
                    "study", "book", "eye", "job", "word", "business",
                    "issue", "side", "kind", "head", "house", "service",
                    "friend", "father", "power", "hour", "game", "line",
                    "end", "member", "law", "car", "city", "community",
                    "name", "president", "team", "minute", "idea", "kid",
                    "body", "information", "back", "parent", "face", "others",
                    "level", "office", "door", "health", "person", "art",
                    "war", "history", "party", "result", "change", "morning",
                    "reason", "research", "girl", "guy", "moment", "air",
                    "teacher", "force", "education"
                )

                $label = $body.Data.options
                | Where-Object name -EQ "circle"
                | Select-Object -expand options
                | Where-Object name -EQ 'label'
                | Select-Object -expand Value
                if ([string]::IsNullOrWhiteSpace($label)) {
                    $verb = $verbs | Get-Random
                    $noun = $nouns | Get-Random
                    $label = "$verb $noun"
                }
                $key = $body.Data.options
                | Where-Object name -EQ "circle"
                | Select-Object -expand options
                | Where-Object name -EQ 'key'
                | Select-Object -expand Value
                if ([string]::IsNullOrWhiteSpace($key)) { $key = Get-Random }

                $playerCircle = @{
                    UserId   = $body.member.user.id
                    Username = $body.member.nick ? $body.member.nick : $body.member.user.username
                    Label    = $label
                    Key      = $key
                    Count    = 1
                    Members  = $body.member.user.id
                    Game     = $existingGame.Id
                }

                $circle = Export-SqlData -Data ([PSCustomObject]$playerCircle) -SqlTable Player -OutputColumns Label, Key
                "INSERT INTO Action (Game,Player,TargetPlayer,Type) VALUES
                ($($existingGame.Id),'$($body.member.user.id)','$($match.UserId)','Create')" | Invoke-SqlQuery
                $message = 'You created a circle labeled `{0}` with key `{1}`.' -f $circle.Label, $circle.Key
                Send-Response -Message $message

                $result = "select count(1) as circleCount from player where game = $($existingGame.Id)" | Invoke-SqlQuery
                if ($result.circleCount -gt (2 * $existingGame.LastReport) -and
                (Get-Date).AddMinutes(-5) -gt $existingGame.LastReportTime) {
                    $timeId = Get-Random 1000
                    $time = Get-Date -Millisecond $timeId -Format 'yyyy-MM-dd HH:mm:ss.ffff'
                    "Update Game set LastReportTime = '$time' where Id = $($existingGame.Id)" | Invoke-SqlQuery
                    Start-Sleep 10
                    if ($existingGame = "Select top 1 * from game where
                        guildId = '{0}'
                        and EndTime > (SYSDATETIME())
                        order by EndTime desc
                        " -f $body.guild_id | Invoke-SqlQuery
                    ) {
                        if (($existingGame.LastReportTime -as [datetime]).Millisecond -eq $timeId) {
                            "Update game set LastReport = $($result.circleCount) where Id = $($existingGame.Id)" | Invoke-SqlQuery
                            $webhookMessage_params = @{
                                # Message  = "There are now {0} circles!" -f $result.circleCount
                                # Username = "Game Maker"
                                Uri      = $existingGame.StatusWebhook
                                Envelope = @{
                                    username = "Game Talker"
                                    embeds   = @(
                                        @{
                                            title       = "Circles Poppin' up"
                                            url         = "https://trustcircle.azurewebsites.net/api/circles?guild=$($body.guild_id)&skip=0&take=10"
                                            description = "There are now {0} circles!" -f $result.circleCount
                                            color       = 0x555555
                                        }
                                    )
                                }
                            }

                            Send-WebhookMessage @webhookMessage_params
                        }
                    }
                }
                return
            }
        }

        "join_circle" {
            if (-not $existingGame) {
                $message = 'No existing game found. Run `/start game` to begin a game.'
                Send-Response -Message $message
                return
            }

            if ($target_result = "Select top 1 * from player where game = $($existingGame.Id) and UserId = '$($body.member.user.id)'" | Invoke-SqlQuery) {}
            else {
                Send-Response "You must create a circle before you can participate"
                return
            }

            $label = $body.Data.options
            | Where-Object name -EQ "circle"
            | Select-Object -expand options
            | Where-Object name -EQ 'label'
            | Select-Object -expand Value

            $key = $body.Data.options
            | Where-Object name -EQ "circle"
            | Select-Object -expand options
            | Where-Object name -EQ 'key'
            | Select-Object -expand Value

            $matched = "Select * from player where
                Game = '$($existingGame.Id)'
                AND [label] = @label
                AND [Key] = @key
                AND Status = 'Intact'
                " | Invoke-SqlQuery -SqlParameters @{
                label = $label
                key   = $key
            }
            if ($matched) {
                $actionCount = 0
                foreach ($match in $matched) {
                    if ($body.member.user.id -in ($match.members -split ',')) {
                        Write-Host "Already in"
                        continue
                    }
                    else {
                        try {
                            "Update Player set count = $(1 + $match.count),members = '$($match.members),$($body.member.user.id)'
                        where Id = $($match.Id)" | Invoke-SqlQuery
                            "Update Player set JoinCount = JoinCount + 1 where UserID = '$($body.member.user.id)' and Game = $($existingGame.Id)" |
                            Invoke-SqlQuery
                            "INSERT INTO Action (Game,Player,TargetPlayer,Type) VALUES
                ($($existingGame.Id),'$($body.member.user.id)','$($match.UserId)','Join')" | Invoke-SqlQuery
                            Write-Host "Added $($body.member.user.id) to $($match.Id)"
                            $overtaken = "Select top 1 * from player where
                            Game = '$($existingGame.Id)'
                            and Label != @label
                            AND count = $($match.count)
                            AND Status = 'Intact'
                            " | Invoke-SqlQuery -SqlParameters @{
                                label = $label
                            }
                            if ($overtaken -and (Get-Date).AddMinutes(-5) -gt $existingGame.LastReportTime) {
                                $timeId = Get-Random 1000
                                $time = Get-Date -Millisecond $timeId -Format 'yyyy-MM-dd HH:mm:ss.ffff'
                                "Update Game set LastReportTime = '$time' where Id = $($existingGame.Id)" | Invoke-SqlQuery
                                Start-Sleep 10
                                if ($existingGame = "Select top 1 * from game where
                                        guildId = '{0}'
                                        and EndTime > (SYSDATETIME())
                                        order by EndTime desc
                                        " -f $body.guild_id | Invoke-SqlQuery
                                ) {
                                    if (($existingGame.LastReportTime -as [datetime]).Millisecond -eq $timeId) {

                                        $Message = 'The circle `{0}` ({1}) has been overtaken by `{2}` ({3})' -f @(
                                            $overtaken.Label
                                            $overtaken.Count
                                            $match.Label
                                            1 + $match.count
                                        )
                                        $webhookMessage_params = @{
                                            Uri      = $existingGame.StatusWebhook
                                            Envelope = @{
                                                username = "Game Stalker"
                                                embeds   = @(
                                                    @{
                                                        title       = 'Circle growth'
                                                        url         = "https://trustcircle.azurewebsites.net/api/circles?guild=$($body.guild_id)&skip=0&take=10"
                                                        description = $message
                                                        color       = 0x5555aa
                                                    }
                                                )
                                            }
                                        }
                                        Send-WebhookMessage @webhookMessage_params
                                    }
                                }
                            }
                            $actionCount++
                        }
                        catch {
                            Send-Response -Message "failed for some reason. Try again?"
                            return
                        }
                    }
                }
                if ($actionCount -eq 1) {
                    Set-DiscordRole Friendship
                    Remove-DiscordRole Treachery

                    $message = "You have joined the circle with label ``$label`` and key ``$key`` (it now has $(1 + $match.count) members)."
                    Send-Response -Message $message
                    return
                }
                elseif ($actionCount -eq 0) {
                    $message = "You have already joined the circle with label ``$label`` and key ``$key`` (it has $($match.count) members)."
                    Send-Response -Message $message
                    return
                }
                elseif ($actionCount -gt 1) {
                    Set-DiscordRole Friendship
                    Remove-DiscordRole Treachery

                    $message = "You joined $actionCount circles with label ``$label`` and key ``$key``"
                    Send-Response -Message $message
                    return
                }
            }
            else {
                Send-Response -Message "No intact circle found with label ``$label`` and key ``$key``"
                return
            }
        }

        "betray_circle" {
            if (-not $existingGame) {
                $message = 'No existing game found. Run `/start game` to begin a game.'
                Send-Response -Message $message
                return
            }
            if ($target_result = "Select top 1 * from player where game = $($existingGame.Id) and UserId = '$($body.member.user.id)'" | Invoke-SqlQuery) {}
            else {
                Send-Response "You must create a circle before you can participate"
                return
            }


            $label = $body.Data.options
            | Where-Object name -EQ "circle"
            | Select-Object -expand options
            | Where-Object name -EQ 'label'
            | Select-Object -expand Value

            $key = $body.Data.options
            | Where-Object name -EQ "circle"
            | Select-Object -expand options
            | Where-Object name -EQ 'key'
            | Select-Object -expand Value

            $matched = "Select * from player where
                Game = '$($existingGame.Id)'
                AND [label] = @label
                AND [Key] = @key
                " | Invoke-SqlQuery -SqlParameters @{
                label = $label
                key   = $key
            }

            if ($matched) {
                $actionCount = 0
                foreach ($match in $matched) {
                    if ('Betrayed' -eq $match.Status) { Write-Host "Already betrayed" }
                    else {
                        if ($body.member.user.id -in ($match.members -split ',')) {
                            Write-Host "Already in"
                            $message = "You have previously joined this circle and cannot betray it."
                            if ($actionCount) { $message += " (But you did also betray a circle with label ``$label``)" }
                            Send-Response -Message $message
                            return
                        }

                        try {
                            "Update Player set Status = 'Betrayed'
                        where Id = $($match.Id)" | Invoke-SqlQuery
                            "INSERT INTO Action (Game,Player,TargetPlayer,Type) VALUES
                ($($existingGame.Id),'$($body.member.user.id)','$($match.UserId)','Betray')" | Invoke-SqlQuery
                            "Update Player set BetrayCount = BetrayCount + 1 where UserID = '$($body.member.user.id)' and Game = $($existingGame.Id)" |
                            Invoke-SqlQuery
                            Write-Host "$($body.member.user.id) betrayed $($match.Id)"
                            $actionCount++
                        }
                        catch {
                            Send-Response -Message "failed for some reason. Try again?"
                            return
                        }
                    }
                }
                if ($actionCount) {
                    Set-DiscordRole Treachery
                    Remove-DiscordRole Friendship

                    $webhookMessage_params = @{
                        Uri      = $existingGame.StatusWebhook
                        Envelope = @{
                            username = "Game Breaker"
                            embeds   = @(
                                @{
                                    title       = "Red ring of death"
                                    url         = "https://trustcircle.azurewebsites.net/api/circles?guild=$($body.guild_id)&label=$([System.Web.HttpUtility]::UrlEncode($label))"
                                    description = "A circle with label ``$label`` was betrayed!"
                                    color       = 0xff0000
                                }
                            )
                        }
                    }
                    Send-WebhookMessage @webhookMessage_params
                }
                if ($actionCount -eq 1) {
                    $message = "You have betrayed the circle with label ``$label`` and key ``$key`` (it had $($match.count) {0})." -f ($match.Count -gt 1 ? "members":"member")
                    Send-Response -Message $message
                    return
                }
                elseif ($actionCount -eq 0) {
                    $message = "You have already betrayed the circle with label ``$label`` and key ``$key`` (it had $($match.count) {0})." -f ($match.Count -gt 1 ? "members":"member")
                    Send-Response -Message $message
                    return
                }
                elseif ($actionCount -gt 1) {
                    $message = "You betrayed $actionCount circles with label ``$label`` and key ``$key``! Devious!"
                    Send-Response -Message $message
                    return
                }
            }
            else {
                Send-Response -Message "No circle found with label ``$label`` and key ``$key`` to betray"
                return
            }
        }

        "score" {
            if ($existingGame = "Select top 1 * from game where
            guildId = '{0}'
            order by EndTime desc
            " -f $body.guild_id | Invoke-SqlQuery
            ) {
                Write-Host "Found existing game"
            }
            if (-not $existingGame) {
                Send-Response -Message "No games found for your server. Start a game first!"
                return
            }

            $target = $body.Data.options
            | Where-Object name -EQ "target"
            | Select-Object -expand Value

            if ($target_result = "Select top 1 * from player where game = $($existingGame.Id) and UserId = '$target'" | Invoke-SqlQuery) {
                $message = "<@$target> has joined $($target_result.JoinCount) {0} and betrayed $($target_result.BetrayCount) {1}." -f @(
                    ($target_result.JoinCount -eq 1 ? "circle" : "circles")
                    ($target_result.BetrayCount -eq 1 ? "circle" : "circles")
                )

                if ($body.member.user.id -eq $target) {
                    $embeds = @()
                    $circles = "Select * from player where
                    (members like '%$($body.member.user.id)%' OR betrayers like '%$($body.member.user.id)%')
                    AND game = $($existingGame.Id)
                    " | Invoke-SqlQuery

                    $memberCircles, $betrayedCircles = @($circles).Where({ $_.members -match $body.member.user.id }, "Split")
                    $embed = @{
                        title       = 'Joined circles'
                        # url         = "https://trustcircle.azurewebsites.net/api/circles?guild=$($body.guild_id)&skip=0&take=10"
                        description = ($memberCircles.Label | ForEach-Object { "``$_``" }) -join "`n"
                        color       = 0x1155bb
                    }
                    if ($ENV:ENV_DEBUG) { $embed }
                    $embeds += $embed
                    if ($betrayedCircles) {
                        $embed = @{
                            title       = 'Betrayed circles'
                            # url         = "https://trustcircle.azurewebsites.net/api/circles?guild=$($body.guild_id)&skip=0&take=10"
                            description = ($memberCircles.Label | ForEach-Object { "``$_``" }) -join "`n"
                            color       = 0xff2211
                        }
                        if ($ENV:ENV_DEBUG) { $embed }
                        $embeds += $embed
                    }

                    Send-Response -response (@{
                            type    = 4
                            content = $message
                            embeds  = $embeds
                        } | ConvertTo-Json)
                    return
                }

                Send-Response -Message $message
                return
            }
            else {
                Send-Response -Message "<@$target> has not begun playing yet"
                return
            }
        }

        "qwestion" {
            if ($existingGame = "Select top 1 * from game where
            guildId = '{0}'
            order by EndTime desc
            " -f $body.guild_id | Invoke-SqlQuery
            ) {
                Write-Host "Found existing game"
            }
            if (-not $existingGame) {
                Send-Response -Message "No games found for your server. Start a game first!"
                return
            }

            $target = $body.Data.options
            | Where-Object name -EQ "target"
            | Select-Object -expand Value

            $circles = "Select * from player where Label = '$target'
            and game = $($existingGame.Id)
            and members like '%$($body.member.user.id)%'" | Invoke-SqlQuery
            $embeds = @()

            foreach ($circle in $circles) {
                $members = $circle.members -split "," | Where-Object { $_ }
                $betrayers = $circle.betrayers -split "," | Where-Object { $_ }

                $title = "{0} ({1}/{2})" -f @(
                    $circle.Label
                    $members.count
                    $betrayers.count
                )
                $desc = "Members: {0}" -f (($members | Sort-Object | ForEach-Object { "<@$_>" }) -join ' ')
                if ($betrayers) {
                    $desc += "`nBetrayers: {0}" -f (($betrayers | Sort-Object | ForEach-Object { "<@$_>" }) -join ' ')
                }
                $hashOutput = Get-FileHash -InputStream ([System.IO.MemoryStream]::New([System.Text.Encoding]::UTF8.GetBytes($circle.Label))) -Algorithm MD5
                $color = ($hashOutput.Hash.Tolower().ToCharArray() | Select-Object -First 6) -join ''
                $embed = @{
                    title       = $title
                    # url         = "https://trustcircle.azurewebsites.net/api/circles?guild=$($body.guild_id)&skip=0&take=10"
                    description = $desc
                    color       = [Convert]::ToInt64($color, 16)
                }
                $embed | Write-Host
                $embeds += $embed
            }

            if ($embeds) {
                $message = "Found the following:"
                Send-Response -response (@{
                        type    = 4
                        content = $message
                        embeds  = $embeds
                    } | ConvertTo-Json)
            }
            else {
                Send-Response -Message "You are not in any circles labeled '$target'"
            }
        }
    }
}

function Set-DiscordRole {
    param(
        $RoleName
    )
    $token = [Environment]::GetEnvironmentVariable("APP_DISCORD_BOT_TOKEN_$($body.application_id)")

    $headers = @{
        Authorization = "Bot $token"
    }
    $irm_splat = @{
        MaximumRetryCount = 1
        RetryIntervalSec  = 1
        ContentType       = 'application/json'
        UserAgent         = 'DiscordBot (https://dcrich.net,0.0.1)'
        Headers           = $headers
        ErrorAction       = 'Stop'
    }

    $irm_splat.Uri = "https://discord.com/api/guilds/$($body.Guild_ID)/roles"
    $roles = Invoke-RestMethod @irm_splat
    $role = $roles | Where-Object { $_.name -eq $RoleName } | Select-Object -First 1
    $irm_splat.Uri = "https://discord.com/api/guilds/$($body.Guild_ID)/members/$($body.member.user.id)/roles/$($role.id)"
    try {
        Invoke-RestMethod @irm_splat -Method Put
    }
    catch {}
}
function Remove-DiscordRole {
    param(
        $RoleName
    )
    $token = [Environment]::GetEnvironmentVariable("APP_DISCORD_BOT_TOKEN_$($body.application_id)")

    $headers = @{
        Authorization = "Bot $token"
    }
    $irm_splat = @{
        MaximumRetryCount = 1
        RetryIntervalSec  = 1
        ContentType       = 'application/json'
        UserAgent         = 'DiscordBot (https://dcrich.net,0.0.1)'
        Headers           = $headers
        ErrorAction       = 'Stop'
    }

    $irm_splat.Uri = "https://discord.com/api/guilds/$($body.Guild_ID)/roles"
    $roles = Invoke-RestMethod @irm_splat
    $role = $roles | Where-Object { $_.name -eq $RoleName } | Select-Object -First 1
    $irm_splat.Uri = "https://discord.com/api/guilds/$($body.Guild_ID)/members/$($body.member.user.id)/roles/$($role.id)"
    try {
        Invoke-RestMethod @irm_splat -Method Delete
    }
    catch {}
}
# This code scrubs DBNulls.  Props to Dave Wyatt and fffnite
# Open a MR for this updated code to go into Invoke-SqlCmd2 module.
$cSharp = @'
    using System;
    using System.Data;
    using System.Management.Automation;

    public class DBNullScrubber
    {
        public static PSObject DataRowToPSObject(DataRow row)
        {
            PSObject psObject = new PSObject();

            if (row != null && (row.RowState & DataRowState.Detached) != DataRowState.Detached)
            {
                foreach (DataColumn column in row.Table.Columns)
                {
                    Object value = null;
                    if (!row.IsNull(column))
                    {
                        value = row[column];
                    }

                    psObject.Properties.Add(new PSNoteProperty(column.ColumnName, value));
                }
            }

            return psObject;
        }
    }
'@

try {
    if ($PSEdition -eq 'Core') {
        # Core doesn't auto-load these assemblies unlike desktop?
        # Not csharp coder, unsure why
        # by fffnite
        $Ref = @(
            'System.Data.Common'
            'System.Management.Automation'
            'System.ComponentModel.TypeConverter'
        )
    }
    else {
        $Ref = @(
            'System.Data'
            'System.Xml'
        )
    }
    Add-Type -TypeDefinition $cSharp -ReferencedAssemblies $Ref -ErrorAction stop
}
catch {
    If (-not $_.ToString() -like "*The type name 'DBNullScrubber' already exists*") {
        Write-Warning "Could not load DBNullScrubber.  Defaulting to DataRow output: $_"
    }
}



Add-Type -Path .\ASodium.dll
