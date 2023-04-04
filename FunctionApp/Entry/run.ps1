using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)


try { Assert-Signature }
catch { return }

if ($Request.Body.type -eq 1) {
    $response = @{
        type = 1
    }
    Write-Host "ACKing ping"
    Close-Response $response
}

$commandName = @(
    $Request.Body.data.name
    $Request.Body.data.options | Where-Object type -EQ 1 | Select-Object -First 1 -expand name
    $Request.Body.data.options.options | Where-Object type -EQ 1 | Select-Object -First 1 -expand name
) -join "_"


$out = Invoke-SqlQuery -Query "select * from game"

$response = @{
    type = 4
    data = @{
        content = "$commandName- out:$($out.start)"
    }
}

Close-Response $response
