# GuideMe

A sleek macOS menu bar app that helps you learn how to perform tasks on your Mac.

## Features

- 🔍 Ask for instructions on how to do anything on your Mac
- 💻 AI-powered responses using GPT-4o-mini
- 📝 Clean, formatted instructions with Markdown
- 🖥️ Floating window stays on top while you follow along
- 🔒 Uses your own OpenAI API key for privacy

## Requirements

- macOS 12.0 or later
- An OpenAI API key (get one at [platform.openai.com/api-keys](https://platform.openai.com/api-keys))

## How to Use

1. Download and launch GuideMe
2. Enter your OpenAI API key when prompted
3. Click the menu bar icon (question mark)
4. Type your question (e.g., "how to take a screenshot" or "set up multiple desktops")
5. View the step-by-step instructions while working on your Mac

## Privacy

GuideMe is privacy-focused:
- Your API key is stored securely in the app
- All requests are made directly from your computer to OpenAI
- No user data is collected or stored

## Development

This app is built with:
- Swift & SwiftUI
- AppKit for menu bar integration
- MarkdownUI for rendering formatted instructions
- Combine for API requests

## License

MIT 