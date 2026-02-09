# MacParakeet Website

Marketing website for [MacParakeet](https://macparakeet.com) - the fastest local transcription app for Mac.

## Tech Stack

- **Framework:** Astro 5.x
- **Styling:** Tailwind CSS 4
- **Deployment:** Vercel

## Development

```bash
# Install dependencies (bun or pnpm)
bun install
# or: pnpm install

# Start dev server (http://localhost:4321)
bun dev
# or: pnpm dev

# Build for production
bun run build

# Preview production build
bun run preview
```

## Project Structure

```
src/
├── layouts/        # Page layouts
├── pages/          # Routes (index, pricing, privacy)
├── components/     # Reusable UI components
└── styles/         # Global styles
public/             # Static assets (images, favicon)
```

## Deployment

Pushes to `main` auto-deploy to Vercel.

- **Production:** https://macparakeet.com
- **Preview:** Auto-generated for PRs

## Related

- [MacParakeet App](https://github.com/moona3k/macparakeet) - The macOS app
- [Oatmeal](https://github.com/moona3k/oatmeal) - Parent product

## License

Proprietary. All rights reserved.
