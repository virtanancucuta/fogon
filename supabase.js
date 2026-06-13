// supabase.js — Cliente Supabase de El Fogón de la Pesa
// La URL y la llave publishable son PÚBLICAS por diseño; la seguridad está en las
// políticas RLS del backend. NUNCA poner aquí (ni en el repo) la service_role.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = 'https://kxacvooiedcuaohxqrbq.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_r8RGfZkOYiRCX4K3PBPNww_LvmE8OCG';

export const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);

// Disponible para las siguientes fases (admin, cocina, mesera, carnet).
window.supabaseClient = supabase;
