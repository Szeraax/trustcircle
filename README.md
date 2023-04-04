# trustcircle
A Discord Circle of Trust bot

## Roadmap

* Add commands to the discord side of the bot
  * start game, circle action, report status
  * Start game: Duration in hours, webhook URI
    * Webhook URI will report on:
    * Circle getting betrayed
    * Circle overtaking another circle
    * End of game
    * Final results leaderboard
  * Circle: Name, password, action (join, create, betray)
  * Report status: List top X circles by size, show the status of circles you're in (status, name, size, password)
* Add functions to profile.ps1 for commands
* Add interaction code paths to FunctionApp/entry/run.ps1 to run the function commands
* Add queue code path for longer duration commands
* Add timer command to prevent cold starts
