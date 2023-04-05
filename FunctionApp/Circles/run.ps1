using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

$Request | ConvertTo-Json -Compress -Depth 10

try {
    [ValidateRange(1, 10000)]
    $top = $request.query.top
}
catch { $top = 10 }


if ($guild = $request.query.guild) { }
else {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = "No guild specified"
        })
}

if ($label = $request.query.label) { $label = "%$label%" }
else { $label = "%" }

$results = "select top $top p.label,p.count from Player p join game g on p.game = g.id where
g.guildId = @guild
and p.label like @label
and g.EndTime > (SYSDATETIME())
order by count desc
" | Invoke-SqlQuery -SqlParameters @{
    guild = $guild
    label = $label
}

if ($results) {
    switch ($Request.Query.Format) {
        "json" {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::OK
                    Body       = $results
                })
        }
        "fragment" {
            $body = $results | ConvertTo-Html -Fragment
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode  = [HttpStatusCode]::OK
                    Body        = $body -join "`n"
                    ContentType = 'text/html'
                })
        }
        default {
            $body = $results | ConvertTo-Html
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode  = [HttpStatusCode]::OK
                    Body        = $body -join "`n"
                    ContentType = 'text/html'
                })
        }
    }
}
else {
    $body = "No matching results for guild $guild."
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
