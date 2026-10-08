import { notFound } from "next/navigation";
import { MenuView } from "@/components/MenuView";
import { restaurantView } from "@/lib/view";

export const dynamic = "force-dynamic";

export default async function RestaurantPage({ params }: { params: Promise<{ id: string }> }) {
  const view = await restaurantView((await params).id);
  if (!view) notFound();
  return <MenuView {...view} />;
}
