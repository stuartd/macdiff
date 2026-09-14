# MacDiff

A focused, native macOS app for comparing two text files side by side. MacDiff uses familiar diff conventions—line numbers, aligned additions and removals, change navigation, and an optional whitespace-insensitive comparison—without merge controls or editing clutter.

## Run

MacDiff requires macOS 14 or later and Xcode 16 (or a compatible Swift 6 toolchain).

```sh
swift run MacDiff
```

Choose **Original** and **Changed** from the file bar. Navigate differences with the toolbar or <kbd>⌘[</kbd> and <kbd>⌘]</kbd>.

## Test

```sh
swift test
```
