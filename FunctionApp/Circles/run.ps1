using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Query parameters:
# skip (offset)
# take (count to return)
# label (label names to filter on)
# guild (guild ID to search)
# ruid (game ID to search)

$Request | ConvertTo-Json -Compress -Depth 10

try {
    [ValidateRange(0, 10000)]
    [int]$skip = $request.query.skip
}
catch { [int]$skip = 0 }
try {
    [ValidateRange(1, 10000)]
    [int]$take = $request.query.take
}
catch { [int]$take = 10 }


if ($guild = $request.query.guild) {
    $gameFilter = "GuildId = @guild"
    $queryFilter = "Guild=$guild"
}
elseif ($ruid = $request.query.ruid) {
    $gameFilter = "Ruid = @ruid"
    $queryFilter = "Ruid=$ruid"
}
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
    guild = $guild
    ruid  = $ruid
}

if (-not $game) {
    $message = "No games found for guild ``$guild``"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = $message
        })
    return
}

$queryBuilder = ""
if ($request.query.Status) {
    $queryBuilder += " AND Status = @status "
}

$script:skip = $skip
if ($label = $request.query.label) {
    $label = "%$label%"
    $results = "select * from Player where
    Game = $($game.Id)
    and label like @label
    $queryBuilder
    order by count desc
    " | Invoke-SqlQuery -SqlParameters @{
        label  = $label
        Status = $request.query.Status
    }
    $results = $results | Select-Object Username, Label, Count, Status
}
elseif ($Request.query.TopJoiners -eq 'true') {
    $results = "select * from Player where
    Game = $($game.Id)
    $queryBuilder
    order by JoinCount desc
    OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
    " | Invoke-SqlQuery -SqlParameters @{
        Skip   = $skip
        Take   = $take
        Status = $request.query.Status
    }
    $results = $results | Select-Object @{n = 'Ranking'; e = { $script:skip++; $script:skip } }, Username, JoinCount, Status
}
elseif ($Request.query.TopBetrayers -eq 'true') {
    $results = "select * from Player where
    Game = $($game.Id)
    $queryBuilder
    order by BetrayCount desc
    OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
    " | Invoke-SqlQuery -SqlParameters @{
        Skip   = $skip
        Take   = $take
        Status = $request.query.Status
    }
    $results = $results | Select-Object @{n = 'Ranking'; e = { $script:skip++; $script:skip } }, Username, BetrayCount, Status
}
elseif ($Request.query.Betrayers -eq 'true') {
    $results = "
    select players.username,count(1) as BetrayalsToday from player Betrayers
    JOIN Player players on Betrayers.Betrayers = players.UserId
    where players.game = $($game.Id)
    group by players.username order by BetrayalsToday desc
    OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
    " | Invoke-SqlQuery -SqlParameters @{
        Skip = $skip
        Take = $take
    }
    $results = $results | Select-Object @{n = 'Ranking'; e = { $script:skip++; $script:skip } }, Username, BetrayalsToday
}
else {
    $results = "select * from Player where
    Game = $($game.Id)
    and label like '_%'
    $queryBuilder
    order by count desc
    OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
    " | Invoke-SqlQuery -SqlParameters @{
        Skip   = $skip
        Take   = $take
        Status = $request.query.Status
    }

    $results = $results | Select-Object @{n = 'Ranking'; e = { $script:skip++; $script:skip } }, Username, Label, Key, Count, Status
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
            $head = @"
                <Title>Leaderboard</Title>
                <style>
                body { background-color:#E5E4E2;
                    font-family:Monospace;
                    font-size:10pt; }
                td, th { border:0px solid black;
                        border-collapse:collapse;
                        white-space:pre; }
                th { color:white;
                    background-color:black; }
                table, tr, td, th { padding: 2px; margin: 0px ;white-space:pre; }
                tr:nth-child(odd) {background-color: lightgray}
                table { margin-left:5px; margin-bottom:20px;}
                h2 {
                font-family:Tahoma;
                color:#6D7B8D;
                }
                .alert {
                color: red;
                }
                .footer
                { color:green;
                margin-left:10px;
                font-family:Tahoma;
                font-size:8pt;
                font-style:italic;
                }
                </style>
"@
            $Uri = $Request.Url -as [Uri]
            $body = $results | ConvertTo-Html -Head $head -PostContent "<a href=`"https://$($Request.Headers.host)$($Uri.AbsolutePath)?ruid=$($game.Ruid)`">Direct link for this game leaderboard</a>
            <br /><br />
            Altername views:<br />
            <a href=`"https://$($Request.Headers.host)$($Uri.AbsolutePath)?$queryFilter&Status=Intact`">Without betrayed circles</a><br />
            <a href=`"https://$($Request.Headers.host)$($Uri.AbsolutePath)?$queryFilter&Betrayers=true`">Today's Top Betrayers</a><br />
            <a href=`"https://$($Request.Headers.host)$($Uri.AbsolutePath)?$queryFilter&TopJoiners=true`">Top player joins</a><br />
            <a href=`"https://$($Request.Headers.host)$($Uri.AbsolutePath)?$queryFilter&TopBetrayers=true`">Top player betrayals</a><br />
            "
            if (-not $body) { $body = "No active circles in game" }
        }
    }
}
else {
    $body = "No matching results for guild $guild."
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::OK
        Body        = $body -join "`n"
        ContentType = 'text/html'
    })
# Associate values to output bindings by calling 'Push-OutputBinding'.
