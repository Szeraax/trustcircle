# Input bindings are passed in via param block.
param($QueueItem, $TriggerMetadata)
$body_raw = $QueueItem | ConvertTo-Json -Depth 10 -Compress
$body = $body_raw | ConvertFrom-Json

# Write out the queue message and insertion time to the information log.
Write-Host "PowerShell queue trigger function processed work item: $QueueItem"
Write-Host "Queue item insertion time: $($TriggerMetadata.InsertionTime)"

function Send-Response {
    param(
        $message,
        $response = (@{
                type    = 4
                content = $message
            } | ConvertTo-Json)
    )
    if ($ENV:ENV_DEBUG -eq 1) { "Response: $response" | Write-Host }
    $invokeRestMethod_splat = @{
        Uri               = "https://discord.com/api/v8/webhooks/{0}/{1}/messages/@original" -f $body.application_id, $body.token
        Method            = "Patch"
        ContentType       = "application/json"
        Body              = $response
        MaximumRetryCount = 5
        RetryIntervalSec  = 1
    }
    $invokeRestMethod_splat.Uri | Write-Host
    try { Invoke-RestMethod @invokeRestMethod_splat | Out-Null }
    catch {
        "failed" | Write-Host
        $invokeRestMethod_splat | ConvertTo-Json -Depth 3 -Compress
        $_
    }
}


$body_raw | Write-Host

Invoke-RequestProcessing -Body $body
