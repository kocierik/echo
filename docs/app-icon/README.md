# App icon

`icon.svg` is the source: sky blue crop circles (#6CCBF5) on graphite (#0E0F10).

To regenerate every size (iOS, Android, web) after editing it:

1. `shot-icon.js` renders `icon-1024.png` with the Puppeteer image.
2. `resize.py` writes all the sizes, without alpha, because iOS refuses it.

Both are run as in the commit that added them.
