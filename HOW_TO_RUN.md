# How to Run OpenSuperWhisper with Cleanup Feature

## Method 1: Run attached to terminal (requires keeping terminal open)
```bash
cd /Users/brandoncharleson/Documents/DeveloperProjects/OpenSuperWhisper
./run.sh run
```

## Method 2: Run independently (can close terminal after launch)
```bash
cd /Users/brandoncharleson/Documents/DeveloperProjects/OpenSuperWhisper
nohup ./build/Build/Products/Debug/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper > /dev/null 2>&1 &
```

## Method 3: Launch as macOS app (simplest)
```bash
cd /Users/brandoncharleson/Documents/DeveloperProjects/OpenSuperWhisper
open ./build/Build/Products/Debug/OpenSuperWhisper.app
```

## To stop the app
```bash
killall OpenSuperWhisper
```

## Features Added
- ✅ Automatic Recording Cleanup
- ✅ Storage Usage Display
- ✅ Manual Cleanup with "Clean Now" button
- ✅ Configurable cleanup intervals
- ✅ Safety confirmations and progress indicators