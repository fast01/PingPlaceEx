# PingPlaceEx
an enhanced version of  pingplace (move macos system notification window to other position, supporting multi-monitor) . 

- enhanced stability, less likely to automatically exit
- can chose different display monitors (will move the system notification window to **the specified window, not the fixed main window**)
- can set the **edge margins** of the window position, to avoid obscuring the dock bar or menu bar.


## Usage

The app needs accessibility permissions to work. It lives in the top bar. 
You can set notifications to appear in eight positions: 

<img width="439" height="439" alt="image" src="https://github.com/user-attachments/assets/550b3ab1-c368-4203-8a0e-842cbd186118" />


## Requirements

- macOS 14 or later
- Accessibility permissions


if can't open the app, you can try these cmds below: 

```
sudo spctl --master-disable
xattr -cr /Applications/PingPlaceEx.app
```

## thanks 
thanks the orignal repo: https://github.com/NotWadeGrimridge/PingPlace    

