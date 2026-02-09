## TODO

- [ ] Make it possible to use the tab key to navigate the UI. Should make it easy to set all the hotkeys using just the keyboard.
- [ ] Strange bug: Open settings window. Then open another app. Press cmd+q on the app, it closes our settings window too.
- [ ] Show how much time in ms it took to switch the app
- [ ] Come up with suggested hotkeys on initial launch
- [ ] Show a message when an app is launched
- [ ] Check if hotkeys work when entering password fields
- [ ] Start at login
- [ ] Add an icon
- [ ] Fix accessibility permission not working when moving bundle to application folder.
- [ ] Does it need to be restarted after granting permissions? Any way to make it easy for the user? Maybe adding a screenshot?
- [ ] Have option to show message when switching apps
- [ ] Make bundling happen in a separate folder. Update .gitignore to remove old bundling excludes if requried
- [ ] Find a more reliable method to find all windows in all spaces (including full screen) in a non-brute force way

## Done

- [x] Fix issue where the first window of an app is focused instead of the last focused window (Solved by sorting by z-order)
- [x] Fix unreliable window cycling when the hotkey is pressed rapidly (Solved by implementing cycling sessions)
- [x] Switch desktops to focus/activate the app if a fullscreen app is covering it
- [x] It sometimes still becomes unable to activate apps. Figure out why
- [x] Figure out why ctrl+escape doesn't work
- [x] Allow editing config with UI
- [x] Allow closing the settings window using escape and cmd+w
- [x] Allow quitting the application using cmd+q
- [x] Allow launching with --settings
- [x] Fix bug with opening settings twice
- [x] Only allow one instance of the application. Launching again should open settings
- [x] Package into an app
- [x] When activating the app, show the settings page
- [x] Simplify settings screen. Remove pencil button. Allow editing directly by clicking
- [x] Allow adding exceptions for apps where hotkeys shouldn't apply
- [x] Show runnings apps so that hotkeys can be assigned
- [x] Show running applications and assigned hotkey applications in the same combined list
- [x] The list should be ordered alphabetically
- [x] Instead of opening up a modal, allow assigning hotkeys right from the list (By clicking on the hotkey area)
- [x] Pressing escape should cancel the hotkey recording, but pressing backspace or delete should unassign it. (All cases avoid closing the window)
- [x] Scroll to the currently recording item and highlight it when adding a new application and recording the hotkey
- [x] When recording shortcuts, don't switch apps
  - [x] Show when there are conflicting hotkeys assigned
- [x] When an app is active but has 0 windows, switching to it shows nothing. It should launch a new window when activated
- [x] Won't fix: AudioRelay has a different name depending on whether a hotkey is assigned or not (And the app is open). Seems to be an issue with the app itself having a misleading localizedName
- [x] Allow switching between multiple fullscreen and windowed apps
- [x] When there are 3+ windows, allow cycling through them all
- [x] Fix not being able to switch between helim windows
