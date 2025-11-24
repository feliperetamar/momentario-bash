#!/bin/bash
set -e

TEST_ROOT="test_hang"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT/origen" "$TEST_ROOT/destino" "$TEST_ROOT/originales"

# Create a base image
convert -size 100x100 xc:blue "$TEST_ROOT/base.jpg"
exiftool -q -overwrite_original -DateTimeOriginal="2024:01:01 12:00:00" "$TEST_ROOT/base.jpg"

# Create collision scenario:
# "Album 1" and "Album_1" both map to "Album_1" in destination.
# We create 20 variations that all map to "Album_1".
# Actually, just "Album 1" and "Album_1" is enough, but let's do more.
# "Album 1", "Album  1", "Album_1", "Album__1" -> All map to "Album_1" (if sanitization replaces space with underscore and maybe squeezes? No, just replaces space).
# "Album 1" -> "Album_1"
# "Album_1" -> "Album_1"

# Let's create 10 copies in "Album 1" and 10 copies in "Album_1".
# They will all go to DEST/2024/Album_1/PXL...
# And since the filename is the same, they collide on the FILE.

mkdir -p "$TEST_ROOT/origen/Album 1"
mkdir -p "$TEST_ROOT/origen/Album_1"

for i in {1..10}; do
    # We need different filenames in source to exist, but they must map to SAME destination file?
    # No, if filenames are different, they go to different files.
    # We need SAME filename in source.
    # So "Album 1/photo.jpg" and "Album_1/photo.jpg".
    
    cp "$TEST_ROOT/base.jpg" "$TEST_ROOT/origen/Album 1/photo_$i.jpg"
    cp "$TEST_ROOT/base.jpg" "$TEST_ROOT/origen/Album_1/photo_$i.jpg"
    
    # This creates collision for photo_1.jpg, photo_2.jpg, etc.
    # 2 concurrent jobs per file.
done

# To increase concurrency on a SINGLE file, we need more sources mapping to the same album.
# "Album 1", "Album_1", "Album__1" (if we rename manually), "Album   1".
# Let's create 5 folders that map to "Album_1".

mkdir -p "$TEST_ROOT/origen/Album 1"
mkdir -p "$TEST_ROOT/origen/Album_1"
mkdir -p "$TEST_ROOT/origen/Album  1"
mkdir -p "$TEST_ROOT/origen/Album__1"
mkdir -p "$TEST_ROOT/origen/Album   1"

cp "$TEST_ROOT/base.jpg" "$TEST_ROOT/origen/Album 1/target.jpg"
cp "$TEST_ROOT/base.jpg" "$TEST_ROOT/origen/Album_1/target.jpg"
cp "$TEST_ROOT/base.jpg" "$TEST_ROOT/origen/Album  1/target.jpg"
cp "$TEST_ROOT/base.jpg" "$TEST_ROOT/origen/Album__1/target.jpg"
cp "$TEST_ROOT/base.jpg" "$TEST_ROOT/origen/Album   1/target.jpg"

# Now we have 5 files that will all try to go to DEST/2024/Album_1/target.jpg
# concurrently.

echo "Running organizer with MAX_JOBS=10..."
export MAX_JOBS=10
./organizar_fotos.sh "$TEST_ROOT/origen" "$TEST_ROOT/destino" "$TEST_ROOT/originales"
