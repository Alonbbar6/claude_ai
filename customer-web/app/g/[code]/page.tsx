import { GroupOrder } from "@/components/GroupOrder";
import { getMenu } from "@/lib/catalog";

export const dynamic = "force-dynamic";

export default async function GroupPage({ params }: { params: Promise<{ code: string }> }) {
  const menu = await getMenu();
  return <GroupOrder code={(await params).code.toUpperCase()} dishes={menu.dishes} />;
}
