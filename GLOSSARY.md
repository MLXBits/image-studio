# MLXBits Image Studio

A macOS app that runs local image models and keeps what they make in a gallery.

## Families and queues

**Family**:
A kind of image model, with its own parameters, queue and sidecar format. Flux, Ideogram 4, Krea 2, Z-Image and Qwen 2.1 are picked in the params panel. SeedVR2 is the upscale family: it acts on an existing image and is never picked.
_Avoid_: pipeline, model type

**Queue**:
A family's ordered list of jobs: waiting, running, finished and failed. Each family has exactly one.
_Avoid_: lane

**Run**:
One job's execution, from its start until it finishes or fails. A fan-out or a multi-image upscale is several runs, one per job.

**Landing**:
One output image of a run reaching disk, after which the gallery can show it. A run has one landing per image.
_Avoid_: completion (the whole run finishing)

**Gate**:
The rule that only one family runs at a time, so two models are never loaded at once.

**Run order**:
The fixed order of families in which the gate picks the next queue that has waiting jobs. Upscales come last.

**Hand-off**:
The moment one family's queue drains and the gate starts the next family in run order.

**Warm driver**:
A long-lived model process that keeps a model loaded between runs, so the next run with the same model skips loading.

## Gallery and replay

**Sidecar**:
The metadata file saved next to each generated image. It records the family and every setting the image was made with.

**Board**:
A folder of the output directory that groups images in the gallery.

**Replay**:
Loading an image's recorded settings back into the params panel. It has two modes: Remix and Apply Settings.

**Remix**:
Replay with a new seed, to get a variation of the image.

**Apply Settings**:
Replay that keeps the recorded seed, to reproduce or adjust the image.
_Avoid_: Load Settings
