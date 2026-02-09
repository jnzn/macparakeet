# CLAUDE.md

> Context for AI coding assistants working on the MacParakeet website.

## What is This?

Marketing website for MacParakeet - a fast, private, local transcription app for Mac.

**Domain:** macparakeet.com

## Tech Stack

| Layer | Choice | Notes |
|-------|--------|-------|
| Framework | Astro 5.x | Static site generation |
| Styling | Tailwind CSS 4 | Utility-first CSS |
| Components | Astro components | `.astro` files |
| Deployment | Vercel | Static hosting |
| Analytics | None | Privacy-first (no tracking) |

## Project Structure

```
macparakeet-website/
├── CLAUDE.md           # This file
├── README.md           # Project overview
├── astro.config.mjs    # Astro configuration
├── tailwind.config.js  # Tailwind configuration
├── package.json
├── src/
│   ├── layouts/
│   │   └── Layout.astro    # Base layout
│   ├── pages/
│   │   ├── index.astro     # Landing page
│   │   ├── pricing.astro   # Pricing page
│   │   └── privacy.astro   # Privacy policy
│   ├── components/
│   │   ├── Header.astro
│   │   ├── Footer.astro
│   │   ├── Hero.astro
│   │   ├── Features.astro
│   │   ├── Pricing.astro
│   │   ├── FAQ.astro
│   │   └── CTA.astro
│   └── styles/
│       └── global.css
├── public/
│   ├── favicon.ico
│   ├── og-image.png        # Social sharing image
│   └── screenshots/        # App screenshots
└── docs/
    └── seo-strategy.md     # SEO planning
```

## Development

```bash
# Install dependencies (prefer bun or pnpm)
bun install
# or: pnpm install

# Start dev server
bun dev

# Build for production
bun run build

# Preview production build
bun run preview
```

## Key Pages

### Landing Page (`/`)
- Hero: "The fastest local transcription for Mac"
- Features: Speed, Privacy, Simplicity
- Social proof: Testimonials/reviews
- Pricing: $49 one-time
- FAQ
- Download CTA

### Pricing (`/pricing`)
- Free trial details
- Pro features ($49)
- Comparison table vs competitors
- FAQ about pricing

### Privacy (`/privacy`)
- Privacy policy
- Data handling (none - all local)
- Security practices

## SEO Strategy

### Target Keywords
| Keyword | Priority | Page |
|---------|----------|------|
| macwhisper alternative | High | Landing |
| mac transcription app | High | Landing |
| local speech to text mac | High | Landing |
| parakeet transcription | Medium | Landing |
| private transcription mac | Medium | Landing |
| offline transcription mac | Medium | Landing |

### Meta Tags (per page)

**Landing Page:**
```html
<title>MacParakeet - The Fastest Local Transcription for Mac</title>
<meta name="description" content="Transcribe audio at 300x speed, entirely on your Mac. No cloud, no subscriptions, no accounts. $49 one-time purchase.">
```

### Structured Data
- Product schema for pricing
- SoftwareApplication schema
- FAQ schema for FAQ section

## Design Guidelines

### Colors
| Name | Hex | Usage |
|------|-----|-------|
| Primary | `#3B82F6` | Buttons, accents |
| Background | `#0F172A` | Dark mode bg |
| Text | `#F8FAFC` | Headings |
| Muted | `#94A3B8` | Body text |

### Typography
- Headings: Inter or SF Pro Display
- Body: System font stack
- Code: JetBrains Mono

### Tone
- **Confident** but not arrogant
- **Technical** but accessible
- **Privacy-focused** messaging
- **No fluff** - direct value props

## Messaging Hierarchy

1. **Speed** - "300x realtime transcription"
2. **Privacy** - "Audio never leaves your Mac"
3. **Simplicity** - "Drag, drop, done"
4. **Fair pricing** - "$49 forever, no subscriptions"

## Copy Guidelines

### Do
- Use specific numbers ("300x faster", "$49")
- Emphasize local/private processing
- Compare to cloud alternatives
- Keep sentences short

### Don't
- Overpromise accuracy numbers
- Bash competitors directly
- Use marketing fluff
- Require accounts to download

## Images Needed

| Image | Dimensions | Purpose |
|-------|------------|---------|
| og-image.png | 1200x630 | Social sharing |
| favicon.ico | 32x32, 16x16 | Browser tab |
| hero-screenshot.png | 1200x800 | Landing hero |
| app-icon.png | 512x512 | App Store style |
| feature-*.png | 600x400 | Feature sections |

## Deployment

### Vercel Setup
1. Connect GitHub repo
2. Auto-deploy on push to `main`
3. Custom domain: macparakeet.com

### Environment Variables
None required (static site)

## Related

- **App repo:** [macparakeet](https://github.com/moona3k/macparakeet)
- **Parent product:** [Oatmeal](https://github.com/moona3k/oatmeal)

---

## Quick Tasks

### Update pricing
1. Edit `src/components/Pricing.astro`
2. Update pricing page `src/pages/pricing.astro`

### Add testimonial
1. Add to `src/components/Testimonials.astro`
2. Include name, role, quote

### Update screenshots
1. Replace files in `public/screenshots/`
2. Update references in components

---

*This file helps AI assistants understand the project quickly.*
