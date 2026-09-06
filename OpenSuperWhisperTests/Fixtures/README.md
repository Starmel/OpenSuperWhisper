# Long-form transcription fixtures

`long_en.m4a` and `long_ru.m4a` are fixed speech snapshots generated once from
the adjacent UTF-8 transcripts with macOS system voices:

```sh
say -v Samantha -r 165 -f long_en.txt -o long_en.aiff
say -v Milena -r 165 -f long_ru.txt -o long_ru.aiff
ffmpeg -i INPUT.aiff -ar 16000 -ac 1 -c:a aac -b:a 48k OUTPUT.m4a
```

They contain checkpoint phrases near the beginning, middle, and end so an
integration test can distinguish formatting regressions from lost or clipped
audio. Some phrases cross the decoder windows near 30, 60, and 90 seconds; the
test inspects the raw segments and verifies ordered, non-duplicated joins. The
fixtures are synthetic and contain no third-party recordings. Keep
the committed M4A files in CI: `say` output can change between macOS and voice
versions, so regenerating them is not byte-for-byte reproducible.

SHA-256:

- `long_en.m4a`: `34c051c05fd076777903aae3694aef7386e9ad92126996cc3839655df1adf691`
- `long_ru.m4a`: `6af9e64b6fc78ee90860da0576632644bb804a5cbedb876c026f54f0e9448326`

The language integration test is opt-in when no multilingual model is present.
Point it at any real multilingual whisper.cpp model:

```sh
OSW_TEST_MULTILINGUAL_MODEL=/path/to/ggml-tiny.bin \
  xcodebuild test -project OpenSuperWhisper.xcodeproj \
  -scheme OpenSuperWhisper -destination 'platform=macOS' \
  -only-testing:OpenSuperWhisperTests/WhisperLongFormLanguageIntegrationTests
```

For a local smoke test, the official multilingual tiny model can be cached in
the path that the test discovers automatically:

```sh
mkdir -p .build/test-models
curl -L --fail \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin \
  -o .build/test-models/ggml-tiny.bin
```
