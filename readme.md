# play.sh

Watch a series continuously, automatically loading the next episode until exiting the media player. 
Resume each video from the exact position that was left off. 

Select a video by title, from a list, or watch a random episode. 

Designed to work with [mpv] media player. 

## Dependencies

* [mpv] for playback
* `jq` for persistent collection state
* `fzf` for interactive selection. (not required if not invoked)

## Usage

```bash
./play.sh dir <--options>
```

The script looks in directory `dir` recursively and finds all movie files. Files will be 
organized in natural order (alphabetical and numeric)

| Command | Description |
|---|---|
| `play.sh StarTrek` | Play the current video, resuming where you left off. If you watch the video to the end, the next video will load next time. |
| `play.sh StarTrek --continue` | If the media player reaches the end of the video, play the next video from the beginning. Continue until the user exits the media player. |
| `play.sh StarTrek --start-over` | Start with the first video. |
| `play.sh StarTrek --name brain` | Play "Spock's Brain". If more than one video matches, present the matching titles for interactive selection. |
| `play.sh StarTrek --title brain` | Same as `--name`. |
| `play.sh StarTrek --select` | Select from the whole series. |
| `play.sh StarTrek --random` | Play a random episode. |
| `play.sh StarTrek --restart` | Restart the video from the beginning rather than resuming where you left off. |
| `play.sh StarTrek --name brain --resume` | Selection options normally start the selected video from the beginning. Use `--resume` to resume it where you left off. |
| `play.sh StarTrek --window` | Start the media player in a window. |
| `play.sh StarTrek --full` | Start the media player fullscreen. |
| `play.sh StarTrek --screen 1` | Play on the 2nd monitor. (0 for first monitor.) |

## Installation

Put `play.sh` in your `PATH` or in your base movie directory. 

## References

[mpv]: https://mpv.io/
