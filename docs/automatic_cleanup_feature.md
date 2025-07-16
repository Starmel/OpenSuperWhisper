# Automatic Recording Cleanup Feature

## Overview

The Automatic Recording Cleanup feature allows OpenSuperWhisper users to automatically delete old recordings based on configurable time periods. This helps manage storage space and keeps the application performant by removing outdated recordings.

## Features

### User Configuration
- **Cleanup Intervals**: Choose from "Keep forever" (default), "1 day", "1 week", "1 month", "3 months", or "6 months"
- **Enable/Disable**: Toggle automatic cleanup on or off
- **Persistent Settings**: Preferences are stored using the existing UserDefaults system

### User Interface
- **Settings Integration**: New "Storage" tab in the Settings view
- **Storage Usage Display**: Shows total recordings count and storage used
- **Cleanup Impact Preview**: Displays estimated storage savings
- **Manual Cleanup**: "Clean Now" button for immediate cleanup
- **Progress Indicators**: Real-time progress during cleanup operations
- **Confirmation Dialogs**: Safety prompts for destructive operations

### Safety Mechanisms
- **In-Use Protection**: Never deletes recordings that are currently being played, transcribed, or processed
- **File Lock Detection**: Checks for files locked by other processes
- **Error Handling**: Graceful handling of permission errors, missing files, and database issues
- **Batch Processing**: Processes deletions in batches to avoid UI blocking
- **Concurrent Limits**: Limits simultaneous file operations to prevent system overload

## Architecture

### Core Components

#### 1. CleanupTimeInterval Enum
```swift
enum CleanupTimeInterval: String, CaseIterable, Codable {
    case never, oneDay, oneWeek, oneMonth, threeMonths, sixMonths
}
```
- Defines available cleanup intervals
- Provides human-readable display names
- Calculates cutoff dates for cleanup operations

#### 2. RecordingCleanupService
```swift
@MainActor class RecordingCleanupService: ObservableObject
```
- Main service responsible for cleanup operations
- Manages periodic cleanup scheduling
- Provides progress tracking and error reporting
- Implements safety checks and batch processing

#### 3. StorageUsageService
```swift
@MainActor class StorageUsageService: ObservableObject
```
- Calculates storage usage statistics
- Provides storage breakdown by time periods
- Estimates cleanup impact for different intervals

### Integration Points

#### App Lifecycle
- **Launch**: Delayed cleanup check (5 seconds after launch)
- **Termination**: Quick cleanup attempt with 2-second timeout
- **Periodic**: Daily cleanup checks at 3 AM

#### Settings System
- Extends existing `AppPreferences` class
- Uses `@UserDefault` property wrapper for persistence
- Maintains backward compatibility

#### UI Framework
- Integrates with existing SwiftUI Settings view
- Follows established UI patterns and styling
- Uses existing confirmation dialog patterns

## Performance Optimizations

### Batch Processing
- Processes recordings in batches of 50
- Limits concurrent file operations to 5
- Yields control between batches for UI responsiveness

### Async Operations
- Uses structured concurrency with TaskGroup
- Implements AsyncSemaphore for operation limiting
- Non-blocking progress updates

### Memory Management
- Processes large datasets in chunks
- Releases resources promptly
- Avoids loading all file data into memory

## Error Handling

### Error Types
```swift
enum CleanupError: Error {
    case fileNotFound(String)
    case permissionDenied(String)
    case databaseError(String)
    case recordingInUse(String)
    case unknown(String)
}
```

### Recovery Strategies
- Continues processing after individual failures
- Reports partial success when some operations succeed
- Provides detailed error information for debugging

### User Notifications
- Shows system notifications for cleanup results
- Differentiates between success, partial success, and failure
- Includes storage savings information

## Testing Strategy

### Unit Tests
- `RecordingCleanupServiceTests`: Core cleanup logic
- `StorageUsageServiceTests`: Storage calculation accuracy
- `CleanupTimeIntervalTests`: Time interval calculations

### Integration Tests
- `CleanupIntegrationTests`: File system operations
- App lifecycle integration
- Concurrent operation handling
- Error recovery scenarios

### Performance Tests
- Large dataset handling (1000+ recordings)
- Large file processing (10MB+ files)
- Memory usage validation
- UI responsiveness verification

## Migration and Compatibility

### Backward Compatibility
- Default cleanup interval: "Keep forever"
- Existing recordings are preserved during migration
- No changes to existing database schema

### User Migration
- One-time notification about new feature
- Clear explanation of cleanup behavior
- Opt-in approach for enabling cleanup

## Usage Guidelines

### For Users
1. **Enable Cleanup**: Go to Settings > Storage > Enable automatic cleanup
2. **Choose Interval**: Select appropriate cleanup interval based on usage
3. **Monitor Usage**: Check storage usage regularly
4. **Manual Cleanup**: Use "Clean Now" for immediate cleanup

### For Developers
1. **Testing**: Run comprehensive tests before deployment
2. **Monitoring**: Check logs for cleanup operation details
3. **Performance**: Monitor app performance with large datasets
4. **User Feedback**: Collect feedback on cleanup behavior

## Configuration

### Default Settings
```swift
cleanupInterval: .never
cleanupEnabled: true
lastCleanupDate: nil
```

### Performance Tuning
```swift
batchSize: 50              // Recordings per batch
maxConcurrentDeletions: 5  // Concurrent file operations
cleanupDelay: 5.0          // Seconds after app launch
terminationTimeout: 2.0   // Seconds for cleanup on quit
```

## Logging

### Log Categories
- **Info**: Cleanup start/end, configuration changes
- **Debug**: Batch processing, individual file operations
- **Warning**: Non-fatal errors, skipped files
- **Error**: Fatal errors, operation failures

### Log Format
```
[RecordingCleanup] Starting cleanup operation (forced: false)
[RecordingCleanup] Found 150 total recordings
[RecordingCleanup] Found 25 recordings to delete
[RecordingCleanup] Processing batch 1 of 1 (size: 25)
[RecordingCleanup] Cleanup completed: deleted 23 recordings, 45MB, 2 errors
```

## Future Enhancements

### Potential Features
- **Smart Cleanup**: ML-based cleanup suggestions
- **Favorites Protection**: Never delete favorited recordings
- **Export Before Delete**: Automatic backup before cleanup
- **Cleanup Scheduling**: Custom cleanup schedules
- **Storage Quotas**: Maximum storage limits with automatic cleanup

### Performance Improvements
- **Background Processing**: Move cleanup to background queue
- **Incremental Cleanup**: Process small batches continuously
- **Predictive Cleanup**: Cleanup based on usage patterns
- **Compression**: Compress old recordings instead of deleting

## Troubleshooting

### Common Issues
1. **Cleanup Not Running**: Check if feature is enabled and interval is not "never"
2. **Files Not Deleted**: Verify file permissions and that files aren't in use
3. **Performance Issues**: Reduce batch size or concurrent operations
4. **Database Errors**: Check database integrity and permissions

### Debug Steps
1. Enable debug logging
2. Check cleanup service status
3. Verify storage calculations
4. Test with small dataset
5. Review error logs

## Security Considerations

### Data Protection
- No sensitive data in logs
- Secure file deletion (when possible)
- Permission validation before operations

### User Privacy
- Local-only operations
- No data transmission
- User control over all operations

This feature enhances OpenSuperWhisper's usability while maintaining the app's focus on privacy and performance.
