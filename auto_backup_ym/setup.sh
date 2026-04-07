#!/bin/bash

echo "🚀 Setting up Python virtual environment..."

# Kiểm tra Python3
if ! command -v python3 &> /dev/null; then
    echo "❌ Python3 not found. Installing..."
    sudo apt update
    sudo apt install -y python3 python3-venv python3-pip
fi

# Tạo venv
echo "📦 Creating virtual environment..."
python3 -m venv venv

# Kích hoạt
echo "✅ Activating virtual environment..."
source venv/bin/activate

# Upgrade pip
echo "⬆️ Upgrading pip..."
pip install --upgrade pip

# Cài dependencies
echo "📥 Installing dependencies..."
if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
else
    echo "⚠️ requirements.txt not found. Creating it..."
    cat > requirements.txt << EOF
flask>=2.3.0,<3.0.0
minio>=7.1.0
requests>=2.31.0
boto3>=1.34.0
botocore>=1.34.0
pytz>=2023.3
psutil>=5.9.0
schedule>=1.2.0
urllib3==1.26.19
EOF
    pip install -r requirements.txt
fi

echo ""
echo "✅ Setup complete!"
echo ""
echo "To activate the virtual environment, run:"
echo "  source venv/bin/activate"
echo ""
echo "To run the service:"
echo "  python minio_service.py"