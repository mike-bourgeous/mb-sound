# Build

```bash
docker build . -t mb-sound
```

# Run

## Automatically attach or create

```bash
./dock.sh
```

## Create

```bash
docker run --name mb-sound -it --rm -v .:/mb-sound mb-sound /bin/bash
```

## Attach extra terminal

```bash
docker exec -it mb-sound /bin/bash
```
