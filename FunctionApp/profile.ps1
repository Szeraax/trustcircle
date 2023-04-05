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
        Invoke-SettlementSql -Query $Query
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

    $commandName = @(
        $body.data.name
        $body.data.options | Where-Object type -EQ 1 | Select-Object -First 1 -expand name
        $body.data.options.options | Where-Object type -EQ 1 | Select-Object -First 1 -expand name
    ) -join "_"
    Write-Host $commandName

    if ($existingGame = "Select top 1 * from game where
            guildId = '{0}'
            and EndTime > (SYSDATETIME())
            " -f $body.guild_id | Invoke-SqlQuery
    ) {
        Write-Host "Found existing game"
    }

    $body | ConvertTo-Json -Depth 10 -Compress | Write-Host
    switch ($commandName) {
        "Start_game" {

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

                if ($duration = ($body.Data.options | Where-Object name -EQ "game").options | Where-Object name -EQ 'end' | Select-Object -expand Value) {
                    $data.EndTime = [System.DateTime]::Now.AddHours($duration).ToUniversalTime()
                }
                if ($webhook = ($body.Data.options | Where-Object name -EQ "game").options | Where-Object name -EQ 'webhook' | Select-Object -expand Value) {
                    $data.StatusWebhook = $webhook
                }

                $existingGame = Export-SqlData -Data ([PSCustomObject]$data) -SqlTable Game -OutputColumns EndTime, StatusWebhook
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
        "End_game" {
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
                $message = "You did not start the game. Please contact <@$($existingGame.InitiatorId)> and have them end the game."
                Send-Response -Message $message

            }
            else {
                $message = "There is no currently running game."
                Send-Response -Message $message
                return
            }

        }

        "circle_create" {
            if (-not $existingGame) {
                $message = 'No existing game found. Run `/start game` to begin a game.'
                Send-Response -Message $message
                return
            }
            $circle = "select p.* from Player p where p.game = '$($existingGame.Id)'" |
            Invoke-SqlQuery -SqlParameters @{guild = $guild }

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
                $label = ($body.Data.options | Where-Object name -EQ "create").options | Where-Object name -EQ 'label' | Select-Object -expand Value
                if ([string]::IsNullOrWhiteSpace($label)) { $label = $body.member.user.username }
                $key = ($body.Data.options | Where-Object name -EQ "create").options | Where-Object name -EQ 'key' | Select-Object -expand Value
                if ([string]::IsNullOrWhiteSpace($key)) { $key = Get-Random }
                $playerCircle = @{
                    UserId  = $body.member.user.id
                    Label   = $label
                    Key     = $key
                    Count   = 1
                    Members = $body.member.user.id
                    Game    = $existingGame.Id
                }

                $circle = Export-SqlData -Data ([PSCustomObject]$playerCircle) -SqlTable Player -OutputColumns Label, Key
                $message = 'You created a circle labeled `{0}` with key `{1}`.' -f $circle.Label, $circle.Key
                Send-Response -Message $message
                return
            }
        }
    }
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
