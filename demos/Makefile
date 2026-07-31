# Convert every .mp4 in this directory to a GitHub-embeddable .gif.
#
# GitHub won't render images over ~10 MiB in READMEs/issues, so each GIF is
# encoded down a quality ladder (fps/width/colors) until it fits under the
# limit; if even the lowest step is too big, the build fails naming the file.
#
# Usage:  make             build gifs for all mp4s (skips up-to-date ones)
#         make LIMIT_MB=8  use a different size cap
#         make clean       remove gifs that have a source mp4

LIMIT_MB ?= 10

# fps:width:max_colors — tried in order until the gif fits under the limit
LADDER := 15:960:128 12:800:128 10:640:96 8:512:64 6:400:48

MP4S := $(wildcard *.mp4)
GIFS := $(MP4S:.mp4=.gif)

# Keep going past a too-big file so every offender is reported in one run.
MAKEFLAGS += --keep-going

.DELETE_ON_ERROR:
.PHONY: all clean

all: $(GIFS)

%.gif: %.mp4
	@set -e; limit=$$(( $(LIMIT_MB) * 1024 * 1024 )); \
	for step in $(LADDER); do \
	    fps=$${step%%:*}; rest=$${step#*:}; width=$${rest%%:*}; colors=$${rest#*:}; \
	    printf '%s: trying fps=%s width=%s colors=%s ... ' '$@' $$fps $$width $$colors; \
	    ffmpeg -loglevel error -y -i '$<' -filter_complex \
	        "[0:v] fps=$$fps,scale='min($$width,iw)':-1:flags=lanczos,split [a][b]; \
	         [a] palettegen=max_colors=$$colors:stats_mode=diff [p]; \
	         [b][p] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
	        '$@'; \
	    size=$$(stat -c %s '$@'); \
	    printf '%d KiB\n' $$(( size / 1024 )); \
	    if [ $$size -le $$limit ]; then exit 0; fi; \
	done; \
	rm -f '$@'; \
	echo "ERROR: $< is too big — GIF exceeds $(LIMIT_MB) MiB even at the lowest quality step" >&2; \
	exit 1

clean:
	rm -f $(GIFS)
