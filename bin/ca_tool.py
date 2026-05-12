#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse, os
from datetime import datetime, timedelta
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
from ipaddress import ip_address

def create_end_entity_certificate(ca_key, ca_cert, entity_key, alt_names, not_before,
                                 valid_days=3650, common_name="localhost",
                                 cert_type="server", dn_attrs={}):
    """Create end entity (server or client) certificate signed by CA.

    Args:
        ca_key: CA private key for signing
        ca_cert: CA certificate
        entity_key: End entity private key
        alt_names: List of SubjectAlternativeName extensions
        not_before: Certificate validity start datetime
        valid_days: Validity period in days
        common_name: Common name for certificate subject
        cert_type: "server" or "client"
        dn_attrs: Dictionary of distinguished name attributes (O, OU etc.)

    Returns:
        Signed X509 certificate
    """
    now = datetime.utcnow()
    not_before = not_before or now
    not_after = not_before + timedelta(days=valid_days)

    # Build subject name
    name_attrs = [x509.NameAttribute(NameOID.COMMON_NAME, common_name)]
    if cert_type == "server":
        name_attrs.extend([
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, dn_attrs.get('O', 'snapmaker.com')),
            x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, dn_attrs.get('OU', 'software'))
        ])

    # Create CSR
    csr_builder = x509.CertificateSigningRequestBuilder()
    csr_builder = csr_builder.subject_name(x509.Name(name_attrs))
    csr_builder = csr_builder.add_extension(
        x509.SubjectAlternativeName(alt_names),
        critical=False,
    )
    csr = csr_builder.sign(entity_key, hashes.SHA256())

    # Configure KeyUsage based on certificate type
    key_usage = x509.KeyUsage(
        digital_signature=True,
        content_commitment=False,
        key_encipherment=True,
        data_encipherment=False,
        key_agreement=(cert_type == "client"),
        key_cert_sign=False,
        crl_sign=False,
        encipher_only=False,
        decipher_only=False
    )

    # Configure ExtendedKeyUsage based on certificate type
    if cert_type == "server":
        extended_key_usage = [x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]
    else:
        extended_key_usage = [
            x509.oid.ExtendedKeyUsageOID.CLIENT_AUTH,
            x509.oid.ExtendedKeyUsageOID.EMAIL_PROTECTION
        ]

    # Sign CSR with CA
    cert_builder = x509.CertificateBuilder()
    cert_builder = cert_builder.subject_name(csr.subject)
    cert_builder = cert_builder.issuer_name(ca_cert.subject)
    cert_builder = cert_builder.not_valid_before(not_before)
    cert_builder = cert_builder.not_valid_after(not_after)
    cert_builder = cert_builder.serial_number(x509.random_serial_number())
    cert_builder = cert_builder.public_key(csr.public_key())
    cert_builder = cert_builder.add_extension(
        x509.BasicConstraints(ca=False, path_length=None),
        critical=True,
    )
    cert_builder = cert_builder.add_extension(
        key_usage,
        critical=True,
    )
    cert_builder = cert_builder.add_extension(
        x509.ExtendedKeyUsage(extended_key_usage),
        critical=False,
    )
    cert_builder = cert_builder.add_extension(
        x509.SubjectKeyIdentifier.from_public_key(csr.public_key()),
        critical=False,
    )
    cert_builder = cert_builder.add_extension(
        x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()),
        critical=False,
    )
    cert_builder = cert_builder.add_extension(
        x509.SubjectAlternativeName(alt_names),
        critical=False,
    )

    certificate = cert_builder.sign(
        private_key=ca_key,
        algorithm=hashes.SHA256(),
    )

    return certificate

# Keep old functions as aliases for backward compatibility
def create_server_certificate(ca_key, ca_cert, server_key, alt_names, not_before, valid_days=3650, server_dn={}):
    return create_end_entity_certificate(
        ca_key, ca_cert, server_key, alt_names, not_before, valid_days,
        common_name=server_dn.get('CN', 'localhost'),
        cert_type="server",
        dn_attrs=server_dn
    )

def create_client_certificate(ca_key, ca_cert, client_key, alt_names, not_before, valid_days=3650, client_cn="client"):
    return create_end_entity_certificate(
        ca_key, ca_cert, client_key, alt_names, not_before, valid_days,
        common_name=client_cn,
        cert_type="client",
        dn_attrs={}
    )

def save_certificate_and_key(cert, private_key, cert_path, key_path, password=None):
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))

    encryption_algorithm = serialization.NoEncryption()
    if password:
        encryption_algorithm = serialization.BestAvailableEncryption(password)

    with open(key_path, "wb") as f:
        f.write(private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=encryption_algorithm
        ))

def generate_private_key():
    """Generate RSA private key.

    Returns:
        RSAPrivateKey: Generated RSA private key object

    Note:
        public_exponent=65537 (0x10001) is standard because:
        1. It's a prime number
        2. Computational efficiency
        3. Sufficient security
        4. Recommended by PKCS#1 standard
    """
    return rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend()
    )

def create_ca_cert(valid_days=365, not_before=None, ca_dn={}):
    """Generate self-signed CA root certificate.

    Args:
        valid_days (int, optional): Validity period in days, default 365.
        not_before (datetime, optional): Effective time, None means current time.

    Returns:
        tuple: (RSAPrivateKey, Certificate) Private key and certificate objects
    """
    ca_key = generate_private_key()

    now = datetime.utcnow()
    not_before = not_before or now
    not_after = not_before + timedelta(days=valid_days)

    # Create self-signed CA certificate
    builder = x509.CertificateBuilder()
    builder = builder.subject_name(x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, ca_dn.get('CN', 'mqtt-broker')),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, ca_dn.get('O', 'snapmaker.com')),
        x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, ca_dn.get('OU', 'software')),
        x509.NameAttribute(NameOID.EMAIL_ADDRESS, ca_dn.get('emailAddress', 'software@snapmaker.com')),
    ]))
    builder = builder.issuer_name(builder._subject_name)
    builder = builder.not_valid_before(not_before)
    builder = builder.not_valid_after(not_after)
    builder = builder.serial_number(x509.random_serial_number())
    builder = builder.public_key(ca_key.public_key())
    builder = builder.add_extension(
        x509.BasicConstraints(ca=True, path_length=None),
        critical=True,
    )
    builder = builder.add_extension(
        x509.KeyUsage(
            digital_signature=True,
            content_commitment=True,
            key_encipherment=False,
            data_encipherment=False,
            key_agreement=False,
            key_cert_sign=True,
            crl_sign=True,
            encipher_only=False,
            decipher_only=False
        ),
        critical=True,
    )
    builder = builder.add_extension(
        x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()),
        critical=False,
    )
    builder = builder.add_extension(
        x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()),
        critical=False,
    )

    ca_certificate = builder.sign(
        private_key=ca_key,
        algorithm=hashes.SHA256(),
    )

    return ca_key, ca_certificate

# Remove deprecated sign_certificate function as its functionality is now covered
# by create_end_entity_certificate()

def generate_random_password(length=16):
    """Generate random password for MQTT account.

    Args:
        length (int): Length of password to generate, default 16

    Returns:
        str: Randomly generated password
    """
    import random
    import string
    chars = string.ascii_letters + string.digits + "!@#$%^&*"
    return ''.join(random.choice(chars) for _ in range(length))

def parse_args():
    """Parse command line arguments for certificate generation.

    Returns:
        Namespace: Argument object containing:
            - output_dir (str): Path to certificate output directory
            - not_before (datetime): Certificate validity start date (YYYYMMDD format)
            - valid_days (int): Validity period in days (must be positive)
            - cert_type (str): Certificate type, one of: 'ca', 'server', 'client'
            - cert_name (str): Base filename for certificate (without extension)
            - password_file (str): Path to MQTT password file (optional)

    Raises:
        ArgumentError: If argument parsing fails or validation errors occur
    """
    parser = argparse.ArgumentParser(description='Generate SSL/TLS certificates')
    parser.add_argument('--password-file', help='MQTT password file path', default='/home/lava/printer_data/mqtt/users.conf')
    parser.add_argument('output_dir', help='Certificate output directory')
    parser.add_argument('not_before', type=lambda s: datetime.strptime(s, '%Y%m%d'),
                       help='Certificate validity start date (YYYYMMDD)')
    parser.add_argument('valid_days', type=int, help='Validity period in days')
    parser.add_argument('cert_type', choices=['ca', 'server', 'client'],
                       help='Certificate type (ca/server/client)')
    parser.add_argument('cert_name', help='Certificate filename (without extension)')
    return parser.parse_args()

def save_certificate(output_dir, cert_name, key, cert=None):
    """Save certificate/private key to files.

    Args:
        output_dir (str): Output directory path
        cert_name (str): Filename (without extension)
        key (RSAPrivateKey): Private key object
        cert (Certificate, optional): Certificate object
    """
    # save key
    key_path = f"{output_dir}/{cert_name}.key"
    with open(key_path, "wb") as f:
        f.write(key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption()
        ))

    # save certificate
    if cert:
        cert_path = f"{output_dir}/{cert_name}.crt"
        with open(cert_path, "wb") as f:
            f.write(cert.public_bytes(serialization.Encoding.PEM))

def load_existing_ca(output_dir):
    """Load existing CA certificate and private key.

    Args:
        output_dir (str): Directory to search

    Returns:
        tuple: Contains either:
            - (RSAPrivateKey, Certificate): Successfully loaded CA key and cert
            - (None, None): No valid CA certificate/key pair found
    """
    import glob

    # Find all potential CA certs and keys
    ca_crt_files = glob.glob(f"{output_dir}/*ca.crt")
    ca_key_files = glob.glob(f"{output_dir}/*ca.key")

    if not (ca_crt_files and ca_key_files):
        return None, None

    # Try to find matching cert/key pairs
    for crt_file in ca_crt_files:
        base_name = os.path.splitext(os.path.basename(crt_file))[0]
        key_file = f"{output_dir}/{base_name}.key"

        if os.path.exists(key_file):
            try:
                with open(crt_file, "rb") as f:
                    ca_cert = x509.load_pem_x509_certificate(f.read(), default_backend())
                with open(key_file, "rb") as f:
                    ca_key = serialization.load_pem_private_key(
                        f.read(),
                        password=None,
                        backend=default_backend()
                    )
                return ca_key, ca_cert
            except Exception as e:
                print(f"Warning: Failed to load CA pair {crt_file}/{key_file}: {str(e)}")
                continue

    return None, None

def generate_single_cert(args):
    """Generate single certificate based on arguments.

    Args:
        args (Namespace): Command line arguments object containing:
            - output_dir (str): Certificate output directory
            - not_before (datetime): Certificate effective date
            - valid_days (int): Validity period in days
            - cert_type (str): Certificate type (ca/server/client)
            - cert_name (str): Certificate filename (without extension)
            - password_file (str): MQTT password file path (optional)

    Process:
        1. For CA certificates:
           - Generate self-signed CA certificate directly
           - Save to specified directory
        2. For end-entity certificates (server/client):
           a. Try to load existing CA cert/key from output_dir
           b. If no valid CA exists:
              - Generate new CA certificate and key
              - Save as ca.crt and ca.key
           c. Use CA to sign end-entity certificate
           d. Save end-entity certificate and key
        3. For client certificates only:
           - Generate random password
           - Create MQTT account with same name as certificate
           - Save clientid to file
    """
    if args.cert_type == "ca":
        key, cert = create_ca_cert(valid_days=args.valid_days, not_before=args.not_before)
        save_certificate(args.output_dir, args.cert_name, key, cert)
    else:
        # Try to load existing CA
        ca_key, ca_cert = load_existing_ca(args.output_dir)

        # If no existing CA, create new one
        if ca_key is None or ca_cert is None:
            print("No existing CA found, generating new CA...")
            ca_key, ca_cert = create_ca_cert(valid_days=args.valid_days, not_before=args.not_before)
            save_certificate(args.output_dir, "ca", ca_key, ca_cert)

        # Generate requested certificate
        key = generate_private_key()

        alt_names = [
            x509.DNSName("localhost"),
            x509.IPAddress(ip_address("127.0.0.1")),
            x509.IPAddress(ip_address("::1"))
        ]

        cert = create_end_entity_certificate(
            ca_key, ca_cert, key, alt_names, args.not_before, args.valid_days,
            common_name=args.cert_name,
            cert_type=args.cert_type,
            dn_attrs={"CN": args.cert_name} if args.cert_type == "server" else {}
        )

        save_certificate(args.output_dir, args.cert_name, key, cert)

if __name__ == "__main__":
    args = parse_args()
    generate_single_cert(args)
