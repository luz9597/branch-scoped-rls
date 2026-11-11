import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Branch-scoped visibility",
  description: "Live Supabase RLS demo: nested organizations, each person sees only their own branch.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
