export interface ConfigRow {
  key: string;
  value: string;
  value_type: string;
  comment: string;
  updated_at: number;
  updated_by: string;
  display?: string;
}
export interface AuditRow {
  id: number;
  key: string;
  action: string;
  old_value: string | null;
  new_value: string | null;
  actor: string;
  ts: number;
}
export interface ApkState {
  enabled?: boolean;
  exists?: boolean;
  url?: string;
  size?: number;
  last_modified?: string;
  metadata?: Record<string, unknown>;
}
export interface ConfigsResponse {
  configs: ConfigRow[];
  audit: AuditRow[];
  apk: ApkState;
}

export interface UserRow {
  id: string;
  email: string | null;
  username: string | null;
  role: string;
  quota_override: number | null;
  banned: boolean;
  email_confirmed: boolean;
  created_at: string | null;
  last_sign_in_at: string | null;
}
export interface UsersResponse {
  users: UserRow[];
  count: number;
  page?: number;
}

export interface FaasService {
  service_id: string;
  name: string;
  function_name: string;
  owner_user_id: string;
  status: string;
  running: boolean;
  deploy_mode: string;
  node_id: string | null;
  public_base_url: string | null;
  routes_count: number;
  active_commit: string | null;
  created_at: string | null;
  deployed_at: string | null;
  instances: number;
  current_capacity: number;
  capacity_min: number;
  capacity_max: number;
}
export interface FaasResponse {
  services: FaasService[];
  overview: { total: number; running: number; stopped: number; total_instances: number };
  deploy_mode: string;
  health: Record<string, unknown>;
}

export interface AgentNode {
  node_id: string;
  name?: string;
  display_name?: string;
  host?: string;
  url?: string;
  visibility?: string;
  status?: string;
  health?: string;
  last_seen?: number | string;
  expires_in_seconds?: number;
  capacity?: number;
  queue_max?: number;
  active_runs?: number;
  queue_depth?: number;
  provider_mode?: string;
  build_version?: string;
  version?: string;
  owner_user_id?: string;
  [k: string]: unknown;
}
export interface AgentsResponse {
  summary: Record<string, number>;
  nodes: AgentNode[];
}
