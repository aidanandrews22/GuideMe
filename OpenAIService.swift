                // Create content items for user message (text + screenshot)
                let userContentItems = [
                    OpenAIRequest.ContentItem(text: isFollowUpStep ? 
                                            "Here is the follow-up step request: \(query). Here is the current screenshot for context." : 
                                            "Here is the user's request: \(query). Provide ONLY THE FIRST STEP. Here is a screenshot of the user's current screen."),
                    OpenAIRequest.ContentItem(imageBase64: screenBase64)
                ] 