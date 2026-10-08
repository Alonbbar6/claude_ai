import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Store, Plus, Trash2, Mail, PackageCheck, Clock, X } from 'lucide-react';
import { useApi, api } from '../lib/api';
import { money, num } from '../lib/format';
import { Card, SectionTitle, Skeleton, Badge, Button, stagger, fadeUp } from '../components/ui';

interface Vendor { id: string; name: string; email: string; phone: string | null; productCount: number; }
interface POItem { ingredientName: string; packs: number; packSize: number; unit: string; pricePerPack: number; lineTotal: number; }
interface PO { id: string; vendorName: string; status: string; total: number; emailTo: string | null; emailSubject: string | null; emailBody: string | null; createdAt: string; items: POItem[]; }

export function Vendors() {
  const vendors = useApi<Vendor[]>('/vendors');
  const orders = useApi<PO[]>('/purchase-orders');
  const [adding, setAdding] = useState(false);
  const [viewPO, setViewPO] = useState<PO | null>(null);
  const [form, setForm] = useState({ name: '', email: '', phone: '' });
  const [saving, setSaving] = useState(false);

  async function addVendor() {
    if (!form.name || !form.email) return;
    setSaving(true);
    try {
      await api('/vendors', { method: 'POST', body: JSON.stringify(form) });
      setForm({ name: '', email: '', phone: '' }); setAdding(false); vendors.refetch();
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
              <div className="mb-4 grid gap-2 rounded-xl glass-inset border border-transparent p-3 sm:grid-cols-4">
                <input placeholder="Vendor name" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })}
                  className="rounded-lg glass-inset border border-transparent px-3 py-2 text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand" />
                <input placeholder="Email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })}
                  className="rounded-lg glass-inset border border-transparent px-3 py-2 text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand" />
                <input placeholder="Phone (optional)" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })}
                  className="rounded-lg glass-inset border border-transparent px-3 py-2 text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand" />
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
              <motion.div key={v.id} variants={fadeUp} className="flex items-start justify-between rounded-xl glass-inset border border-transparent p-3">
                <div className="min-w-0">
                  <div className="font-semibold">{v.name}</div>
                  <div className="truncate text-xs text-muted">{v.email}</div>
                  <div className="mt-1"><Badge tone="neutral">{v.productCount} products</Badge></div>
                </div>
                <button onClick={() => remove(v.id)} className="text-muted hover:text-danger"><Trash2 size={15} /></button>
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
