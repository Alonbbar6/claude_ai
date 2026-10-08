/** @type {import('next').NextConfig} */
const nextConfig = {
  // PGlite ships WASM + data files that must not be bundled.
  serverExternalPackages: ["@electric-sql/pglite", "firebase-admin"],
  images: { unoptimized: true },
  poweredByHeader: false,
};
export default nextConfig;
