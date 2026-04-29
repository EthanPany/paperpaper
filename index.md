---
title: paperpaper — Support
---

# paperpaper

A macOS app that rotates a fresh photograph onto your desktop on whatever schedule you like, and writes a short note about the place in each shot — quietly, on your own machine.

## Support

For help, bug reports, or feature requests:

- **Issues**: [github.com/EthanPany/paperpaper/issues](https://github.com/EthanPany/paperpaper/issues)
- **Email**: pyy122759996@gmail.com

We typically respond within a couple of days.

## Common questions

**The captions aren't showing up.**
The AI captions are generated locally by [Ollama](https://ollama.com) running on your Mac. paperpaper functions normally without Ollama — captions are just blank. To enable them: install Ollama, then run `ollama pull qwen3-vl:2b-instruct` and make sure the Ollama app is running.

**Photos aren't downloading.**
paperpaper fetches from Unsplash. Open Settings → Connections to confirm your Unsplash access key is set. The app guides you through generating a free key on first launch.

**Where's my data?**
Local only. paperpaper does not collect, transmit, or store any personal data. See the [privacy policy](./privacy/).

## Privacy

Read the full privacy policy: [privacy](./privacy/).
