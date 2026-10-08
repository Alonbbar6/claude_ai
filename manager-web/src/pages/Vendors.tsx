import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Store, Plus, Trash2, Mail, PackageCheck, Clock, X, Tag } from 'lucide-react';
import { useApi, api } from '../lib/api';
import { money, num } from '../lib/format';
import { Card, SectionTitle, Skeleton, Badge, Button, stagger, fadeUp } from '../components/ui';

type Relationship = 'local' | 'regional' | 'corporate';
interface VendorProduct { id: string; ingredientId: string; ingredientName: string; pricePerPack: number; packLabel: string | null; }
interface Vendor { id: string; name: string; email: string; phone: string | null; relationship: Relationship; productCount: number; products?: VendorProduct[]; }
interface POItem { ingredientName: string; packs: number; packSize: number; unit: string; pricePerPack: number; lineTotal: number; }
interface PO { id: string; vendorName: string; status: string; total: number; emailTo: string | null; emailSubject: string | null; emailBody: string | null; createdAt: string; items: POItem[]; }
interface InvItem { id: string; name: string; unit: string; packLabel?: string | null; }

const REL_LABEL: Record<Relationship, string> = { local: 'Local', regional: 'Regional', corporate: 'Corporate' };
const REL_TONE: Record<Relationship, 'ok' | 'neutral' | 'warn'> = { local: 'ok', regional: 'neutral', corporate: 'warn' };

export function Vendors() {
  const vendors = useApi<Vendor[]>('/vendors');
  const orders = useApi<PO[]>('/purchase-orders');
  const inventory = useApi<InvItem[]>('/inventory');
  const [adding, setAdding] = useState(false);
  const [viewPO, setViewPO] = useState<PO | null>(null);
  const [manage, setManage] = useState<string | null>(null); // vendor id whose products are open
  const [form, setForm] = useState<{ name: string; email: string; phone: string; relationship: Relationship }>({ name: '', email: '', phone: '', relationship: 'regional' });
  const [saving, setSaving] = useState(false);

  async function addVendor() {
    if (!form.name || !form.email) return;
    setSaving(true);
    try {
      await api('/vendors', { method: 'POST', body: JSON.stringify(form) });
      setForm({ name: '', email: '', phone: '', relationship: 'regional' }); setAdding(false); vendors.refetch();
    } finally { setSaving(false); }
  }
  async function remove(id: string) { await api(`/vendors/${id}`, { method: 'DELETE' }); vendors.refetch(); }
  async function receive(id: string) { await api(`/purchase-orders/${id}/receive`, { method: 'POST', body: JSON.stringify({}) }); orders.refetch(); vendors.refetch(); }

  return (
    <div className="space-y-6">
      {/* Vendors */}
      <Card>
        <SectionTitle right={<Button variant="ghost" onClick={() => setAdding((a) => !a)}><Plus size={15} /> Add provider</Button>}>
          <span className="flex items-center gap-1.5"><Store size={14} /> Vendors</span>
        </SectionTitle>

        <AnimatePresence>
          {adding && (
            <motion.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }} exit={{ opacity: 0, height: 0 }} className="overflow-hidden">
              <div className="mb-4 grid gap-2 rounded-xl glass-inset border border-transparent p-3 sm:grid-cols-5">
                <input placeholder="Vendor name" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })}
                  className="rounded-lg glass-inset border border-transparent px-3 py-2 text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand" />
                <input placeholder="Email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })}
                  className="rounded-lg glass-inset border border-transparent px-3 py-2 text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand" />
                <input placeholder="Phone (optional)" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })}
                  className="rounded-lg glass-inset border border-transparent px-3 py-2 text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand" />
                <select value={form.relationship} onChange={(e) => setForm({ ...form, relationship: e.target.value as Relationship })}
                  className="rounded-lg glass-inset border border-transparent px-3 py-2 text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand"
                  title="Relationship sets the voice of the AI-written purchase-order email">
                  <option value="local">Local (warm, personal)</option>
                  <option value="regional">Regional (professional)</option>
                  <option value="corporate">Corporate (formal)</option>
                </select>
                <Button onClick={addVendor} disabled={saving || !form.name || !form.email}>{saving ? 'Saving…' : 'Save vendor'}</Button>
              </div>
            </motion.div>
          )}
        </AnimatePresence>

        {vendors.loading ? (
          <div className="space-y-2">{Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-14 w-full" />)}</div>
        ) : vendors.data!.length === 0 ? (
          <p className="py-8 text-center text-sm text-muted">No vendors yet. Add one with “Add provider”.</p>
        ) : (
          <motion.div variants={stagger} initial="initial" animate="animate" className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {vendors.data!.map((v) => (
              <motion.div key={v.id} variants={fadeUp} className="rounded-xl glass-inset border border-transparent p-3">
                <div className="flex items-start justify-between">
                  <div className="min-w-0">
                    <div className="font-semibold">{v.name}</div>
                    <div className="truncate text-xs text-muted">{v.email}</div>
                    <div className="mt-1 flex flex-wrap items-center gap-1">
                      <Badge tone={REL_TONE[v.relationship] ?? 'neutral'}>{REL_LABEL[v.relationship] ?? 'Regional'}</Badge>
                      <Badge tone="neutral">{v.productCount} products</Badge>
                    </div>
                  </div>
                  <button onClick={() => remove(v.id)} className="text-muted hover:text-danger"><Trash2 size={15} /></button>
                </div>
                <button onClick={() => setManage((m) => (m === v.id ? null : v.id))}
                  className="mt-2 flex items-center gap-1 text-xs font-medium text-brand hover:underline">
                  <Tag size={12} /> {manage === v.id ? 'Hide products' : 'Manage products'}
                </button>
                <AnimatePresence>
                  {manage === v.id && (
                    <motion.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }} exit={{ opacity: 0, height: 0 }} className="overflow-hidden">
                      <VendorProducts vendor={v} inventory={inventory.data ?? []} onChange={() => vendors.refetch()} />
                    </motion.div>
                  )}
                </AnimatePresence>
              </motion.div>
            ))}
          </motion.div>
        )}
      </Card>

      {/* Purchase orders */}
      <Card>
        <SectionTitle>Purchase orders</SectionTitle>
        {orders.loading ? (
          <div className="space-y-2">{Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-14 w-full" />)}</div>
        ) : orders.data!.length === 0 ? (
          <p className="py-8 text-center text-sm text-muted">No orders yet. Place one from the Cart.</p>
        ) : (
          <ul className="space-y-2">
            {orders.data!.map((po) => (
              <li key={po.id} className="flex flex-wrap items-center gap-3 rounded-xl glass-inset border border-transparent p-3">
                <span className={`grid h-9 w-9 shrink-0 place-items-center rounded-lg ${po.status === 'received' ? 'bg-ok/15 text-ok' : 'bg-warn/15 text-warn'}`}>
                  {po.status === 'received' ? <PackageCheck size={18} /> : <Clock size={18} />}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <span className="font-semibold">{po.vendorName}</span>
                    <Badge tone={po.status === 'received' ? 'ok' : 'warn'}>{po.status}</Badge>
                  </div>
                  <div className="text-xs text-muted">{po.items.length} item(s) · {money(po.total)} · {new Date(po.createdAt).toLocaleString()}</div>
                </div>
                <Button variant="ghost" onClick={() => setViewPO(po)}><Mail size={14} /> Email</Button>
                {po.status === 'sent' && <Button onClick={() => receive(po.id)}><PackageCheck size={14} /> Mark received</Button>}
              </li>
            ))}
          </ul>
        )}
      </Card>

      <AnimatePresence>
        {viewPO && (
          <motion.div className="fixed inset-0 z-50 grid place-items-center bg-black/50 p-4" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={() => setViewPO(null)}>
            <motion.div className="glass glass-strong w-full max-w-lg rounded-2xl p-5" initial={{ scale: 0.95, y: 12 }} animate={{ scale: 1, y: 0 }} exit={{ scale: 0.95, y: 12 }}
              transition={{ type: 'spring', stiffness: 300, damping: 26 }} onClick={(e) => e.stopPropagation()}>
              <div className="mb-3 flex items-center justify-between">
                <h3 className="text-lg font-bold">Order email — {viewPO.vendorName}</h3>
                <button onClick={() => setViewPO(null)} className="text-muted hover:text-text"><X size={18} /></button>
              </div>
              <div className="space-y-1 text-sm">
                <div><span className="text-muted">To:</span> {viewPO.emailTo}</div>
                <div><span className="text-muted">Subject:</span> {viewPO.emailSubject}</div>
              </div>
              <pre className="mt-3 max-h-80 overflow-y-auto whitespace-pre-wrap rounded-xl glass-inset border border-transparent p-3 text-sm">{viewPO.emailBody}</pre>
              <div className="mt-3 flex justify-end">
                <Button variant="ghost" onClick={() => navigator.clipboard?.writeText(viewPO.emailBody ?? '')}>Copy email</Button>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}



/** Attach the ingredients a vendor sells, each with a price per pack. The
 *  backend already exposes POST /vendors/:id/products (upsert by ingredient). */
function VendorProducts({ vendor, inventory, onChange }: { vendor: Vendor; inventory: InvItem[]; onChange: () => void }) {
  const [ingredientId, setIngredientId] = useState('');
  const [price, setPrice] = useState('');
  const [saving, setSaving] = useState(false);
  const [list, setList] = useState<VendorProduct[]>(vendor.products ?? []);

  async function refreshProducts() {
    const all = await api<Vendor[]>('/vendors');
    const mine = all.find((x) => x.id === vendor.id);
    setList(mine?.products ?? []);
    onChange();
  }

  async function add() {
    const p = Number(price);
    if (!ingredientId || !(p > 0)) return;
    setSaving(true);
    try {
      await api(`/vendors/${vendor.id}/products`, { method: 'POST', body: JSON.stringify({ ingredientId, pricePerPack: p }) });
      setIngredientId(''); setPrice('');
      await refreshProducts();
    } finally { setSaving(false); }
  }

  // Ingredients not already priced for this vendor.
  const taken = new Set(list.map((p) => p.ingredientId));
  const options = inventory.filter((i) => !taken.has(i.id));

  return (
    <div className="mt-2 space-y-2 rounded-lg glass-inset border border-transparent p-2.5">
      {list.length > 0 && (
        <ul className="space-y-1">
          {list.map((p) => (
            <li key={p.id} className="flex items-center justify-between text-xs">
              <span className="truncate">{p.ingredientName}{p.packLabel ? ` · ${p.packLabel}` : ''}</span>
              <span className="font-semibold">{money(p.pricePerPack)}/pack</span>
            </li>
          ))}
        </ul>
      )}
      <div className="grid grid-cols-[1fr_auto_auto] gap-1.5">
        <select value={ingredientId} onChange={(e) => setIngredientId(e.target.value)}
          className="rounded-md glass-inset border border-transparent px-2 py-1.5 text-xs focus:outline-none focus-visible:ring-2 focus-visible:ring-brand">
          <option value="">Add ingredient…</option>
          {options.map((i) => <option key={i.id} value={i.id}>{i.name}{i.packLabel ? ` (${i.packLabel})` : ''}</option>)}
        </select>
        <input type="number" min="0" step="0.01" inputMode="decimal" placeholder="$/pack" value={price} onChange={(e) => setPrice(e.target.value)}
          className="w-24 rounded-md glass-inset border border-transparent px-2 py-1.5 text-xs focus:outline-none focus-visible:ring-2 focus-visible:ring-brand" />
        <Button variant="ghost" onClick={add} disabled={saving || !ingredientId || !(Number(price) > 0)}>
          <Plus size={13} /> {saving ? '…' : 'Add'}
        </Button>
      </div>
    </div>
  );
}
