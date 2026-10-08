import type { Metadata, Viewport } from "next";
import { cookies } from "next/headers";
import { Lato } from "next/font/google";
import { AppProvider } from "@/components/AppProvider";
import { LANG_COOKIE, isLang } from "@/lib/i18n";
import "./globals.css";

const lato = Lato({ subsets: ["latin"], weight: ["400", "700", "900"], variable: "--font-lato" });

export const metadata: Metadata = {
  title: "BarMade — Order ahead",
  description: "Skip the line. Order from your phone and pick it up when it's ready.",
};

export const viewport: Viewport = { themeColor: "#FAF7F0", width: "device-width", initialScale: 1 };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const c = (await cookies()).get(LANG_COOKIE)?.value;
  const lang = isLang(c) ? c : "en";
  return (
    <html lang={lang} className={lato.variable}>
      <body className="min-h-dvh font-sans antialiased">
        <AppProvider initialLang={lang}>{children}</AppProvider>
      </body>
    </html>
  );
}
