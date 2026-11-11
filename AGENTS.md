# Platform parity

When changing a SoundBase feature on iOS or watchOS, inspect its macOS counterpart and update it in the same change wherever the workflow applies. Check the SwiftUI entry points, shared implementation, and platform adapters. Keep common behavior in shared code.

Build the Mac scheme and the changed mobile schemes. Exercise the affected workflow on each applicable platform when available. Report any platform-specific differences, missing parity, or verification gaps before calling the change complete.
