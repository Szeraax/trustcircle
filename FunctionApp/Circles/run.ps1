using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

$Request | ConvertTo-Json -Compress -Depth 10

try {
    [ValidateRange(1, 10000)]
    $top = $request.query.top
}
catch { $top = 10 }


if ($guild = $request.query.guild) { $gameFilter = "guildId = @guild" }
elseif ($gameId = $request.query.game) { $gameFilter = "Id = @gameId" }
else {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = "No guild or game specified"
        })
    return
}

$game = "select top 1 * from game WHERE $gameFilter
order by EndTime desc
" | Invoke-SqlQuery -SqlParameters @{
    guild  = $guild
    gameID = $gameId
}

if (-not $game) {
    $message = "No games found for guild ``$guild``"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NoContent
            Body       = $message
        })
    return
}


if ($label = $request.query.label) {
    $label = "%$label%"
    $labelFilter = 'and label like @label'
}

$results = "select top $top * from Player where
Game = $($game.Id)
$labelFilter
order by count desc
" | Invoke-SqlQuery -SqlParameters @{
    label = $label
}

if ($results) {
    $results = $results | Select-Object Username, Label, Count, Status, Game
    if ([datetime]::UtcNow -lt $game.EndTime) {
        $results = $results | Select-Object * -ExcludeProperty Username
    }

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
            $body = $results | ConvertTo-Html -PostContent "Note: The Discord Username is displayed if the game is already concluded."
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
