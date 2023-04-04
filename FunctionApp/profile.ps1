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
        $Query,
        $ConnectionTimeout = 30,
        $QueryTimeout = 4
    )

    if ($ENV:APP_DB_INSTANCE -and $ENV:APP_DB_DATABASE -and $ENV:APP_DB_USERNAME -and $ENV:APP_DB_PASSWORD) {}
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

function Close-Response {
    param(
        $response,
        [HttpStatusCode]$statusCode = "OK"
    )
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = $statusCode
            Body       = $response
        })
    return
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
