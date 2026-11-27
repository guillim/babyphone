# App Store images

The screenshots, the header and the search results image of the App Store page are built here.

    python3 Store/build.py

The images land in `Store/out/`, which is not committed. Building needs Google Chrome and
the Pillow package (`pip3 install pillow`).

| Image | Size | Where it goes in App Store Connect |
| --- | --- | --- |
| `iphone-*.png` | 1320 × 2868 | App Previews and Screenshots, iPhone |
| `ipad-*.png` | 2064 × 2752 | App Previews and Screenshots, iPad 13" |
| `duo-*.png` | 2007 × 2853 | App Previews and Screenshots, iPhone Duo |
| `header.png` | 3840 × 1646 | Header and Search Results, Header |
| `search.png` | 3840 × 2560 | Header and Search Results, Search Results |

`header-debug.png` and `search-debug.png` show Apple's safe area as a dashed frame:
what matters must stay inside it, the rest may be cropped.

## What the images are made of

- `captures/` holds the app's own screens, taken in the simulator in English.
  When the interface changes, replace them with new captures of the same size.
- `scene.svg` is a drawing of a baby asleep in a cot. The simulator has no camera, so the
  live screen shows no picture there: `composite.py` puts the drawing behind the screen's
  real controls. A capture from two real devices would be better, and would replace both.
- The captions, their order and the layouts are at the top of `build.py`.
