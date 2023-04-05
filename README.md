# trustcircle
A Discord Circle of Trust bot

## Roadmap

* Add commands to the discord side of the bot
  * [√] Main commands
    * [√] start game
    * [√] stop game
    * [√] circle actions
    * [√] report status
    * [√] admin change circle name
    * [√] admin delete circle
  * [√] Start game: Duration in hours, webhook URI (only 1 active game per server at a time)
    * [ ] Circle milestones (every 25? appsetting?)
    * [√] Circle getting betrayed
    * [ ] Circle overtaking another circle
    * [√] End of game
    * [ ] Final results leaderboard
  * [√] Circle: Name, password, action (join, create, betray)
  * [√] Report status: List top X circles by size, show the status of circles you're in (status, name, size, password)
* [√] Add functions to profile.ps1 for commands
* [√] Add interaction code paths to FunctionApp/entry/run.ps1 to run the function commands
* [√] Add queue code path for longer duration commands
* [X] Add timer command to prevent cold starts
* [√] Prevent you from betraying a circle after joining it
* [ ] Change your circle key
* [ ] Allow other discord guilds to join the game?
  * Requires bot to be in their guild. Cross guild talking won't work though.....
