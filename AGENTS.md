# AGENTS.md

## Build Instructions

To build the project from command line:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project myPhoto.xcodeproj -scheme myPhoto -configuration Debug -destination "platform=macOS" build
```

Or open `myPhoto.xcodeproj` in Xcode and press Cmd+B.

## Project Structure

- **Models/** — SwiftData models (Journey, DailySchedule, PhotoItem, Tag, Person)
- **Services/** — Business logic (ExifService, ThumbnailService, PhotoScannerService, GPSInferenceService)
- **ViewModels/** — @Observable view models for state management
- **Views/** — SwiftUI views organized by feature area
- **Extensions/** — Color theme, Date formatting, View helpers

## Architecture

- MVVM pattern with SwiftUI
- SwiftData for persistence
- @Observable macro for view models
- ObservableObject for services that need @Published

## Key Design Decisions

1. Arrays in @Model are non-optional with defaults ([])
2. @Relationship without inverse: to avoid circular macro expansion issues
3. UUID-based navigation selection (not PersistentIdentifier)
4. Thumbnails stored in .myphoto_thumbnails/ inside the photo directory
