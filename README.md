# audiobook-prepare

Based on the [auto-m4b](https://github.com/seanap/auto-m4b) made by seanap but adapted to my own needs.

This is a docker container that will watch a folder for new books, auto convert mp3 books to chapterized m4b, and move all m4b books to a specific output folder.

## Intended Use
This is meant to be an automated step between aquisition and tagging.
* Install via docker-compose 
* Save new audiobooks to /input folder.
* All multifile m4b/mp3/m4a/ogg books will be converted to a chapterized m4b and saved to an /untagged folder  

## Known Limitations

* The chapters are based on the mp3 tracks. A single mp3 file will become a single m4b with 1 chapter, also if the mp3 filenames are garbarge then your m4b chapternames will be terrible as well.  See section on Chapters below for how to manually adjust.
* This folder assumes that each subfolder in `/input` volume will contain exactly one book.
* The conversion process actually strips some tags and covers from the files, which is why you need to use a tagger (mp3tag or beets.io) before adding to Plex.

## How to use
This docker uses the following folders which should be mapped as volumes:
/input: File scanned for audiobooks to be handled
/ouput: Location where the handled audiobooks will be placed in individual subfolders
/failed: Location where failed audiobooks will be placed
/ebookfiles: Location where any ebook files discovered will be placed
/config: Location where a logfile (processing.log) will be placed

## Installation

1. Install docker https://docs.docker.com/engine/install/ubuntu/
2. Manage docker as non-root https://docs.docker.com/engine/install/linux-postinstall/
3. Install docker-compose https://docs.docker.com/compose/install/
4. Create the compose file:  
    `nano docker-compose.yml`
5. Paste the yaml code below into the compose file, and change the volume mount locations
6. Put a test mp3 in the /temp/recentlyadded directory.
7. Start the docker (It should convert the mp3 and leave it in your /temp/untagged directory. It runs automatically every 5 min)  
    `docker-compose up -d`
## Using docker-compose.yml
*  Map the volumes as needed
*  Replace the PUID and PGID with your user ( [?](https://www.carnaghan.com/knowledge-base/how-to-find-your-uiduserid-and-gidgroupid-in-linux-via-the-command-line/) 

### Environment variables

| Environment variable | Description                                                     |
| :------------------- | :-------------------------------------------------------------- |
| PUID                 | Id of the user running the application                          |
| PGUID                | Id of the group of the user running the application             |
| CPU_CORES            | Number of CPU cores to use for m4b-tool                         |
| MONITOR_DIR          | Set to 1 to keep running the application to check for new files |
| SLEEPTIME            | Time to sleep between each run, only used if MONITOR_DIR is 1   |

