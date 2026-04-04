# Implementation Plan - Dynamic Album Covers

This plan introduces support for animated album covers (videos) in the Audiorr app. It includes a backend mapping system, an admin interface for management, and frontend changes to render the animations edge-to-edge on iOS.

## Proposed Changes

### Backend

#### [NEW] [animatedArtworkService.ts](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/backend/src/services/animatedArtworkService.ts)
- Manage `animated-artwork.db` SQLite database.
- Table `album_mappings`: `album_id` (TEXT, PK), `file_path` (TEXT), `updated_at` (DATETIME).
- Methods to get/set/delete mappings.
- Method to list `.mp4` files in `/app/animated-artwork`.

#### [NEW] [animatedArtwork.routes.ts](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/backend/src/routes/animatedArtwork.routes.ts)
- `GET /api/animated-artwork/files`: Returns list of available videos.
- `GET /api/animated-artwork/album/:id`: Returns mapped file for album.
- `PUT /api/animated-artwork/album/:id`: Sets mapping.
- `DELETE /api/animated-artwork/album/:id`: Removes mapping.
- **Static Route**: Serve `/app/animated-artwork` as static files so frontend can stream them.

#### [MODIFY] [server.ts](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/backend/src/server.ts)
- Instantiate `AnimatedArtworkService`.
- Register `animatedArtworkRouter`.
- Add `app.use('/animated-artwork', express.static('/app/animated-artwork'))`.

---

### Frontend

#### [MODIFY] [backendApi.ts](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/frontend/src/services/backendApi.ts)
- Add functions to interact with the new `/api/animated-artwork` endpoints.

#### [NEW] [AdminAnimatedArtworkPanel.tsx](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/frontend/src/components/AdminAnimatedArtworkPanel.tsx)
- UI to search for albums (using Navidrome API).
- UI to select a video file from the available list.
- Display current mappings and allow deletion.

#### [MODIFY] [AdminPage.tsx](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/frontend/src/components/AdminPage.tsx)
- Integrate `AdminAnimatedArtworkPanel` as a new tab.

#### [MODIFY] [AlbumDetail.tsx](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/frontend/src/components/AlbumDetail.tsx)
- Fetch animated artwork mapping on component mount using `albumId`.
- Pass `animatedArtworkUrl` to [PageHero](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/frontend/src/components/PageHero.tsx#50-339).

#### [MODIFY] [PageHero.tsx](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/frontend/src/components/PageHero.tsx)
- Accept `animatedArtworkUrl` prop.
- Render a `<video>` element with absolute positioning, `z-index: 0`, and `object-fit: cover`.
- Video attributes: `autoPlay`, `muted`, `loop`, `playsInline`.
- Adjust CSS to ensure "notch to bottom" coverage if requested.

---

### iOS Layout (Edge-to-Edge)

#### [MODIFY] [index.html](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/frontend/index.html)
- Ensure `<meta name="viewport" content="...viewport-fit=cover">` is present.

#### [MODIFY] [PageHero.tsx](file:///Volumes/Macintosh_HD/Users/user948118/Downloads/audiorr/frontend/src/components/PageHero.tsx) (Refinement)
- Ensure `-mt-60px` or similar logic correctly overcomes the header spacing for a truly immersive experience.

## Verification Plan

### Automated Tests
- No specific automated tests exist for this UI/Integration flow yet. I will rely on manual verification first.

### Manual Verification
1. **Admin Flow**:
   - Go to Admin -> Animated Artwork.
   - Search for "Thriller".
   - Select "thriller_dynamic.mp4" from the dropdown.
   - Click "Save".
   - Verify it appears in the list of mappings.
2. **Dynamic Cover**:
   - Go to the "Thriller" album detail page.
   - Verify the video background is playing.
   - Verify it looks good on iPhone (notch area should be covered by video/header color).
3. **Fallback**:
   - Go to an album without dynamic artwork.
   - Verify it still shows the static cover and gradient background.
