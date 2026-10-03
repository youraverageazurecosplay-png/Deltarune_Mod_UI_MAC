# DELTARUNE Mod Installer

This macOS installer package installs "DELTARUNE Mod Installer.app" in
/Applications. It does not launch the app after installation; open it from
Applications when you are ready to patch. Before updating, the package closes
an older running copy of the installer.

## Obtaining the Windows game files (for .xdelta mods)
1. Open Steam's console by entering "steam://nav/console" in a browser and
   choosing Open Steam.
2. In the Steam console, enter "@sSteamCmdForcePlatformType windows" and
   press Return.
3. In that same Steam session, uninstall DELTARUNE, then install it again.
   Steam should download the Windows version; wait for the download to finish.
4. In Steam, open DELTARUNE's Properties or game page and choose Browse local
   files. Confirm the folder contains Windows game files, including chapter
   folders such as chapter1_win and their data.win files.
5. Copy the complete Windows game folder to a separate folder you can keep.
   When choosing the Windows source in this app, select that copied folder
   (or a parent folder containing chapterN_win/data.win).
6. To restore the Mac game files, quit Steam and reopen it without the
   force-Windows setting, then reinstall DELTARUNE through Steam. Keep the
   copied Windows folder; this app reads it as a patch source and does not
   modify it.

## Using it
1. The Mac target can be a folder that directly contains chapter1_mac,
   chapter2_mac, etc. (such as the supplied Base DR folder), the Steam
   DELTARUNE folder, or DELTARUNE.app. The app first checks the default Steam
   folder at ~/Library/Application Support/Steam/steamapps/common/DELTARUNE,
   then searches Steam libraries. If no valid Mac target is found, it asks you
   to choose a valid folder or app.
2. Click "Choose mod files…" and select one .xdelta patch. You can also drag
   and drop a single .xdelta file onto the mod-selection area. .csx scripts
   and the Custom Difficulty preset are not supported.
3. For an .xdelta patch, select the copied Windows DELTARUNE source folder
   containing chapter1_win/data.win, chapter2_win/data.win, etc.
   (chapterN_windows is also accepted). Do not choose the Mac folder here.
   The Windows folder is saved on this Mac; use its button to change it later.
4. Select the chapter in "Chapter to patch", then click "Patch Selected
   Chapter". In the prompt, leave "Save patched file as an instance" checked
   and enter a name to keep it in the instances list, or uncheck it to apply
   the patch without saving an instance.
   - .xdelta is tested against that chapter's chapterN_win/data.win. If the
     patch is for a different chapter or game version, installation stops
     without changing the Mac game.
5. On success, the patched output is activated as game.ios in the matching
   chapterN_mac folder. If instance saving was selected, it is also stored in
   the instances list. An existing game.ios is backed up alongside it before
   replacement. The CLI output panel shows only the patch tool's captured
   stdout and stderr, without installer-generated command lines, status text,
   or summaries. Installation status and errors appear separately in the app.
   Use "Copy Console" beside the output label to copy all visible output.
   On failure, any output produced by the patch tool remains visible so you
   can copy it, correct the selection, and retry.
6. Saved patches can be reused as instances. To bring back an older mod,
   choose its chapter, use "Import game.ios…" to select the old patched
   game.ios or an installer backup, enter an instance name, then select it and
   click "Apply Instance". Applying an instance backs up the currently active
   game.ios before switching. "Remove Instance" permanently deletes the selected
   saved copy after confirmation; it does not change the currently active game
   file. "Show All Instances in Finder" opens the folder containing every
   chapter's saved instances.
7. Use "Back Up All Original Mac Files" to copy every existing
   chapterN_mac/game.ios in the selected Mac target to its matching
   chapterN_mac/game.ios.original. Pressing it again refreshes all those
   backups from the currently active files. "Restore Original" restores only
   the currently selected chapter; "Restore All Original Mac Files" restores
   every chapter with an original backup. Restoring replaces the active
   game.ios directly; it does not make another backup.
8. Click "Cancel Installation" while a patch or saved instance is being
   applied to stop the current operation and close the installer window. The
   app waits for the patch process to stop before exiting. A cancelled patch
   is not activated; if its output was already saved as an instance, that
   instance remains available to apply later. If cancelling while applying a
   saved instance, the active game.ios is left unchanged.
9. To add a custom song, choose or drag an `.ogg` file onto the custom song
    drop area. It is copied into the selected target's shared `mus` folder and
    is not activated or renamed by the installer. Your mod should reference
    the song by its filename. Existing files are never overwritten; rename the
    new song if a file with the same name already exists.

## Saved instances

Instances are stored separately for the current Mac user in
~/Library/Application Support/DELTARUNE Mod Installer/Instances, grouped by
chapter. They remain available when the installer package is reinstalled.
Installing a new mod does not overwrite saved instances.

## Before using
- For .xdelta mods, follow the supplied "How to mod DELTARUNE on your mac"
  guide to obtain and copy the Windows game files; the Windows copy must
  contain chapterN_win folders with data.win files. Restore/reinstall the Mac
  game files through Steam separately.
- Keep the Windows chapter files from the same DELTARUNE version required by
  the mod. The patch is matched by xDelta's source checksum, not by its name.
- A folder target must directly contain chapterN_mac folders. A DELTARUNE.app
  target must contain them under Contents/Resources.
- Patch decoding uses the bundled xdelta3 command-line tool.
- Quit DELTARUNE before installing a patch. The app never downloads game files,
  changes Steam's platform setting, or modifies Windows source files.

The package is unsigned and not notarized. On macOS, you may need to control-
click the installed app and choose Open the first time you launch it.

## Build
Run "bash build-pkg.sh" on an Apple Silicon Mac with Xcode Command Line Tools
and Homebrew xdelta, xz, and blake3. The package preinstall script closes an
older instance of this installer before updating; it does not launch the app.
The build script embeds xdelta3 and its runtime libraries. The app uses the
supplied multicolored-heart icon. The package does not stop DELTARUNE or other
apps.
See the bundled THIRD-PARTY-NOTICES.txt for included software notices.
