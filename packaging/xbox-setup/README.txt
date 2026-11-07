GT3 Revisited for Xbox - setup
==============================

Plays your own Gran Turismo 3 A-spec disc image on an Xbox Series X|S in Developer Mode.
No game data comes with this: you need your own disc image (.iso or .chd).

What you need
-------------
- An Xbox Series X|S in Developer Mode. That takes a Microsoft developer account (a one-off
  fee): see "Xbox Developer Mode activation" on Microsoft's site. Afterwards the console starts
  into Dev Home.
- Device Portal turned on: Dev Home > Remote Access Settings > Enable Device Portal, and set a
  user name and password there. Dev Home shows the console's IP address.
- A Windows 10/11 PC on the same network as the console.
- A USB drive with 5 GB free or more. It must be NTFS for the Xbox to let the game read it; the
  setup can format it for you (that erases it, and it asks first).
- For HD textures (optional): an NVIDIA RTX graphics card, about 10 GB of free space and an hour
  or more.

How
---
1. Unzip this folder somewhere with space (e.g. Documents\GT3R-Xbox-Setup).
2. Plug the USB drive into the PC.
3. Drag your disc image onto Setup.bat (or double-click Setup.bat and pick it).
4. Answer its questions. It:
   - checks the disc image,
   - installs the latest GT3 Revisited on the console,
   - prepares the USB drive and copies the disc image onto it,
   - optionally makes HD textures from your disc and puts them on the console.
5. Then, on the Xbox:
   - Plug in the USB drive. If it asks how to use it, choose media, NOT game storage.
   - Dev Home: highlight GT3 Revisited > View details > App type: Game.
   - Start it and pick the disc image on the USB drive (usually E:) when it asks.

Run Setup.bat again later to update to a newer release; steps already done are skipped.
If something stops it, the message says why; setup.log has the details.

Your HD textures are made from your own disc: keep them to yourself.
