import { Home } from "@/components/Home";
import { getMenu } from "@/lib/catalog";
import { RESTAURANTS } from "@/lib/content";
import { toViewRestaurant } from "@/lib/view";

export const dynamic = "force-dynamic";

export default async function Page() {
  const menu = await getMenu();
  const special = menu.special ? menu.dishes.find((d) => d.id === menu.special!.dishId) ?? null : null;
  return (
    <Home
      restaurants={RESTAURANTS.map(toViewRestaurant)}
      special={special && menu.special ? { dish: special, reason: menu.special.reason } : null}
      dishes={menu.dishes}
    />
  );
}
