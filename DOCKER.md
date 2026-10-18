# Build

```bash
docker build . -t mb-sound
```

# Run

The image works in `/app` (mount the repository there) and sets
`OUTPUT_TYPE=null`: the container has no sound card, so `play` runs silently.
Render files to listen to on the host (`render 'x.flac', graph, seconds: 4`,
or a script's `-o x.flac`).  Run `bundle exec rake compile` once in the
container before `bin/sound.rb`.

## Automatically attach or create

```bash
./dock.sh
```

## Create

```bash
docker run --name mb-sound -it --rm -v .:/app mb-sound /bin/bash
```

## Attach extra terminal

```bash
docker exec -it mb-sound /bin/bash
```
