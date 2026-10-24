# Lumen website

Compact Ukrainian product website for Lumen. The public site contains one product page and a website privacy page. It does not fetch or show live outage data.

Public URL: https://maksim0-debug.github.io/Lumen/

Application and website repository: https://github.com/maksim0-debug/Lumen

## Local development

From the repository root, enter `website/`. Node.js 22 or later is required. There are no production or build dependencies to install.

```sh
cd website
npm run build
npm run check
npm start
```

Open http://127.0.0.1:4173/Lumen/. The preview binds to loopback, uses the production project path and returns a real 404 for missing pages. Checks cover metadata, internal links, assets, ownership files, artifact boundaries and HTTP routing.

## Publishing

The single source of truth is this repository's `website/` directory. There is no separate website repository or synchronization step.

GitHub Pages must use **GitHub Actions** as its publishing source. A push to `main` that changes `website/**` or `.github/workflows/website.yml` runs the website workflow. It builds and checks `website/dist/`, then deploys only that generated directory. A manual workflow dispatch can republish unchanged source.

Application-only changes do not redeploy the website. The existing application release workflow remains independent. Website downloads follow the latest application's published release automatically.

After a successful deployment, run `npm run check:live` from `website/` to compare the deployed public files with the local build, check crawler user agents and verify missing/source-only paths return 404.

## Content maintenance

- All download buttons use verified `releases/latest/download/` asset names from the application repository. They follow the latest release without hardcoding a version.
- Keep claims, visible descriptions, JSON-LD and `llms.txt` aligned. Actual power monitoring requires a user-configured sensor; local desktop API access is not a public cloud API.
- The main screenshot is the user-provided replacement with the obsolete lightning marker removed. Other screenshots come from the application README. Their origins and dimensions are recorded in `assets/screenshots/sources.json`. All contain historical example data.
- After replacing a screenshot, preserve its aspect ratio, regenerate `assets/social.png`, and update the content-hash query parameters on its HTML and JSON-LD image URLs.
- Update sitemap `lastmod` only after a material change to the corresponding page.
- Keep the website privacy description accurate if tracking, forms, cookies, or third-party runtime requests are added.
- Ratings and testimonials must not be invented. Missing software-app rich-result eligibility is preferable to unsupported ratings.

## Search registration

In the owner's Google Search Console account, add the **URL-prefix** property `https://maksim0-debug.github.io/Lumen/`. Use the supplied HTML ownership proof, published unchanged at:

https://maksim0-debug.github.io/Lumen/googlecb163c8d2d73a784.html

Keep this file in source and published output after verification. If Google supplies a different file for the new property, add that exact file at the website source root; the build preserves `google*.html` files. The old host-root property does not replace verification of the new prefix after the root site is removed.

Submit https://maksim0-debug.github.io/Lumen/sitemap.xml and inspect/request indexing of the main page. Verification, submission and indexing are separate steps; deployment does not confirm indexing.

Add the new site prefix in Bing Webmaster Tools by importing its verified Search Console property or using Bing's verification. The build also preserves `BingSiteAuth.xml`.

After deployment, run `npm run submit:indexnow` to notify participating search engines about both content pages. The script verifies the deployed public ownership file, sends its explicit project-local `keyLocation` and submits only URLs within `/Lumen/`. HTTP 200/202 means receipt, not guaranteed indexing. The hexadecimal `.txt` file is an intentionally public ownership proof, not a private credential.

## Project-path crawler limits

Search engines read robots rules only at `https://maksim0-debug.github.io/robots.txt`. The file under `/Lumen/robots.txt` is a documented reference, not a host-wide control. With the old root website removed, a root robots.txt returning 404 does not block crawling; submit the project's sitemap directly in search tools.

`/Lumen/llms.txt` is an optional product fact sheet linked from the HTML. It does not guarantee AI recommendations, crawling, indexing or ranking.

The former root website URL cannot redirect after its repository is deleted. Update links in profiles and announcements to the new project URL. Do not retain a duplicate repository just to publish a redirect.

## Future domain changes

Update `scripts/site-config.mjs`, all absolute first-party URLs in HTML, JSON-LD, sitemap, robots, `llms.txt` and the manifest together. Configure the domain in GitHub Pages, verify DNS and HTTPS, then verify its Search Console property. Confirm canonical URLs, redirects and crawler behavior before retiring any previous address.
