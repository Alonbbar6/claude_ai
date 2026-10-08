import type { Config } from "tailwindcss";

// BarMade palette (getbarmade.com): gold #A57F00 on black, Lato.
// Lightened for daytime ordering: warm cream background, gold as accent only.
const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        cream: "#FAF7F0",
        ink: { DEFAULT: "#333333", soft: "#5C5C5C", faint: "#888888" },
        line: "#E8E2D4",
        gold: {
          DEFAULT: "#A57F00", // brand: buttons, badges, large accents
          hover: "#AC8608",
          text: "#8A6A00", // 5:1 on white, for small gold text (prices)
          tint: "#F5EDD6",
        },
        night: "#141414",
        fresh: { DEFAULT: "#2F7D4F", tint: "#E3F2E8" }, // available / safe for you
        warn: { DEFAULT: "#B4531A", tint: "#FBEADF" },
      },
      fontFamily: { sans: ["var(--font-lato)", "Arial", "sans-serif"] },
      boxShadow: { card: "0 1px 2px rgba(20,20,20,.06), 0 4px 16px rgba(20,20,20,.06)" },
    },
  },
  plugins: [],
};
export default config;
