#pragma once

// Copiar como TrustAnchor.h (ignorado por Git). Pegar el certificado raíz
// PEM que valida la cadena TLS actual de <project-ref>.supabase.co.
// No pegar la clave privada ni confiar en el certificado hoja del servidor.
#define SUPABASE_ROOT_CA_PEM R"SUPABASE_CA(
PEGAR_AQUI_EL_CERTIFICADO_RAIZ_PEM_VALIDADO
)SUPABASE_CA"
