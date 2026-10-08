import Link from "next/link";
import credits from "@/public/images/credits.json";

export const metadata = { title: "Photo credits — BarMade" };

type Credit = { source: string; author: string; url: string; license: string };

const LICENSE_URL: Record<string, string> = {
  CC0: "https://creativecommons.org/publicdomain/zero/1.0/",
  "CC BY 2.0": "https://creativecommons.org/licenses/by/2.0/",
  "CC BY 3.0": "https://creativecommons.org/licenses/by/3.0/",
  "CC BY 4.0": "https://creativecommons.org/licenses/by/4.0/",
  "CC BY-SA 2.0": "https://creativecommons.org/licenses/by-sa/2.0/",
  "CC BY-SA 3.0": "https://creativecommons.org/licenses/by-sa/3.0/",
  "CC BY-SA 4.0": "https://creativecommons.org/licenses/by-sa/4.0/",
};

export default function CreditsPage() {
  const rows = Object.entries(credits as Record<string, Credit>);
  return (
    <main className="mx-auto max-w-3xl px-4 py-10">
      <Link href="/" className="text-sm font-bold text-gold-text">
        ← BarMade
      </Link>
      <h1 className="mt-4 text-3xl font-black text-night">Photo credits</h1>
      <p className="mt-2 text-ink-soft">
        Trattoria food photos from Wikimedia Commons, cropped and resized for this classroom demo. Illustrations for
        La Ventanita de Calle 8, Brickell Sushi Co., Wynwood Greens and the Funghi Pizza are original artwork made
        for this demo. Restaurant names and menus other than the dataset are fictional.
      </p>
      <ul className="mt-6 divide-y divide-line rounded-2xl bg-white shadow-card">
        {rows.map(([file, c]) => (
          <li key={file} className="flex items-center gap-4 p-3">
            <img src={`/images/${file}`} alt="" loading="lazy" className="h-14 w-14 shrink-0 rounded-lg object-cover" />
            <div className="min-w-0 text-sm">
              <p className="truncate font-bold text-night">{file}</p>
              <p className="truncate text-ink-soft">
                <a href={c.url} className="underline" target="_blank" rel="noopener noreferrer">
                  {c.author}
                </a>{" "}
                ·{" "}
                {LICENSE_URL[c.license] ? (
                  <a href={LICENSE_URL[c.license]} className="underline" target="_blank" rel="noopener noreferrer">
                    {c.license}
                  </a>
                ) : (
                  c.license
                )}
              </p>
            </div>
          </li>
        ))}
      </ul>
    </main>
  );
}
