using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)
$body = $Request.Body

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
    try { Invoke-RestMethod @invokeRestMethod_splat | Out-Null }
    catch {
        "failed" | Write-Host
        $invokeRestMethod_splat | ConvertTo-Json -Depth 3 -Compress
        $_
    }

    [HttpStatusCode]$statusCode = "OK"
    if ($ENV:ENV_DEBUG -eq 1) { "Response: $message" | Write-Host }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = $statusCode
            Body       = $message
        })
}

Invoke-RequestProcessing $body
