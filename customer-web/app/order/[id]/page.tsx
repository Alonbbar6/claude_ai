import { OrderTracker } from "@/components/OrderTracker";

export default async function OrderPage({ params }: { params: Promise<{ id: string }> }) {
  return <OrderTracker id={(await params).id} />;
}
