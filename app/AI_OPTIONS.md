# RunFuel AI and chat options

RunFuel uses **Google Gemini for in-app AI answers**. It does not download or run Basic/Advanced offline models. The standard/default is **Gemini 3.5 Flash-Lite** (`gemini-3.5-flash-lite`), Google's current stable Flash-Lite model. Google does **not** list a `gemini-3.6-flash-lite` model ID. The next capability option is **Gemini 3.6 Flash** (`gemini-3.6-flash`), and the most advanced option in RunFuel is **Gemini 3.8 Flash** (`gemini-3.8-flash`).

**Model lifecycle note (checked 4 November 2026):** Google's model lifecycle documentation lists Gemini 3.6 Flash for retirement on **19 November 2026**. It remains selectable for now to preserve the requested intermediate tier, but it may stop working after that date. Gemini 3.5 Flash-Lite and Gemini 3.8 Flash are the recommended stable choices. Check Google's live [model list](https://ai.google.dev/gemini-api/docs/models) before relying on a model for long-term use.

## In-app coaching — Google Gemini

RunFuel sends your coaching request directly from your Android phone to Google's Gemini API using your own Google AI Studio API key. The key is stored in Android secure storage. It is not sent to the RunFuel backend or Vercel, and RunFuel does not include a shared maintainer key.

### Configure Gemini

1. Open [Google AI Studio — API keys](https://aistudio.google.com/app/apikey).
2. Sign in and create or select an API key for the Gemini API.
3. In RunFuel, open **AI Coach → Coaching tools → Configure Gemini API key**.
4. Paste the key, choose one of the models offered by the app, and save. New installs default to Gemini 3.5 Flash-Lite. Existing saved selections that are no longer supported are safely reset to this default.
5. Ask a question in the Coach chat. Review the exact data-sharing preview before approving the request.

When a key is configured, Gemini is the in-app answering engine. If the request fails, RunFuel reports the error and does not silently substitute a local/offline answer. You can retry or use the ChatGPT handoff instead.

### What is sent to Google?

Before each Gemini request, RunFuel shows a confirmation with the exact payload. The payload can include your question and recent coach conversation, up to 30 days of locally saved activity, nutrition, sleep, recovery, goals and training history, and daily check-in notes included in the preview.

GPS tracks, provider credentials and saved health-profile documents are excluded. Always inspect the preview and cancel if you do not want to share the displayed information.

### Google data use and billing

Google's terms, pricing, quotas, model availability and data handling can change. Check the current terms for your Google project and API tier. Google's unpaid Gemini API tier may use prompts and responses to improve its products, and human reviewers may review them. Do not send sensitive personal health information using the unpaid tier. Google states that eligible paid API requests made through a project with active billing are not used to improve its products. Confirm current terms and billing status directly with Google.

An API key does not guarantee unlimited or free access. Rate limits, quotas and charges may apply.

## Continue in ChatGPT

RunFuel retains the **Open ChatGPT** handoff and **Paste Reply** workflow. You can review and share a prepared prompt containing your question, recent conversation and structured RunFuel context through Android's share sheet, choose ChatGPT, then paste its response back into RunFuel. RunFuel does not send anything to ChatGPT automatically; you choose the receiving app in the share sheet.

The separate **Export coaching history** action creates a reviewable JSON file with up to 30 days of structured coaching context for sharing with ChatGPT, Claude or another tool. Review exported content before sharing it.

## Conversation archive

RunFuel automatically archives the current conversation when Android terminates the app process. Returning to RunFuel after switching to ChatGPT or another app does not archive the chat, so the handoff and paste-reply workflow remains intact. Archived chats can be reopened from **Archived chats**. Archives remain stored on this device until you delete them.

## Key safety

- Never commit your API key or include it in source code, screenshots or support messages.
- If a key is exposed, revoke it in Google AI Studio and create a replacement.
- Review the exact data-sharing confirmation before every Gemini request.
- Review exported text or JSON before sharing it with another app.

## Further information

- [Google AI Studio API keys](https://aistudio.google.com/app/apikey)
- [Gemini API documentation](https://ai.google.dev/gemini-api/docs)
- [RunFuel Android build instructions](BUILD.md)
