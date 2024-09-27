#!/bin/bash
set -e  # Ket thuc script khi gap loi
export de_project="de-c1w2"  # Dat ten du an
export AWS_DEFAULT_REGION="us-east-1"  # Dat vung AWS

# Lay VPC ID tu DB instance
export VPC_ID=$(aws rds describe-db-instances --db-instance-identifier $de_project-rds --output text --query "DBInstances[].DBSubnetGroup.VpcId")

# Lay dia chi IP cong cong cua EC2 instance
export instance_public_ip=$(ec2-metadata --public-ip | grep -oE '[0-9]+(\.[0-9]+)+')

# Lay Instance ID tu dia chi IP cong cong
export instance_id=$(aws ec2 describe-instances --query "Reservations[].Instances[?PublicIpAddress=='$instance_public_ip'].InstanceId" --output text)

# Duong dan den file yeu cau
REQUIREMENTS_FILE="$(pwd)/scripts/requirements.txt"

# Quan ly instance profile cho EC2
inst_prof=$(aws ec2 describe-iam-instance-profile-associations --query 'IamInstanceProfileAssociations[?contains(InstanceId, `'$instance_id'`) == `true`].AssociationId' --output text)

echo "===> ASSOCIATING NEW INSTANCE PROFILE TO LAB EC2 INSTANCE <==="

# Neu khong co profile, gan moi, neu co thi thay the
$(if [ -z $inst_prof ]
then
    echo "    
    associating LabEC2InstanceProfile... ... ...
    "
    aws ec2 associate-iam-instance-profile --iam-instance-profile Name=LabEC2InstanceProfile --instance-id $instance_id
else
    echo "    
    replacing:" $inst_prof "by LabEC2InstanceProfile
    "
    aws ec2 replace-iam-instance-profile-association --iam-instance-profile Name=LabEC2InstanceProfile --association-id $(aws ec2 describe-iam-instance-profile-associations --query 'IamInstanceProfileAssociations[?contains(InstanceId, `'$instance_id'`) == `true`].AssociationId' --output text)
fi )

# Xac minh su lien ket cua IAM instance profile
echo "===> VERIFYING ASSOCIATION <==="

# Lay thong tin profile da lien ket
$(aws ec2 describe-iam-instance-profile-associations  --filters 'Name=instance-id,Values='$instance_id'' --query 'IamInstanceProfileAssociations[*].IamInstanceProfile.Arn' --output text > /tmp/msg.txt)
$(cat /tmp/msg.txt)

# Tat quan ly thong tin xac thuc tu dong
echo "============================> DISABLING AUTOMATIC CREDENTIALS MANAGEMENT <=============================================================================
$(/usr/local/bin/aws cloud9 update-environment --environment-id $C9_PID --managed-credentials-action DISABLE)
"

# Lay security group ID tu EC2 instance
export security_group_id=$(aws ec2 describe-instances --output table --query 'Reservations[*].Instances[*].NetworkInterfaces[*].Groups[*].GroupId' --region $AWS_DEFAULT_REGION --instance-ids $instance_id --output text)

# Them quy tac ingress cho cong 8888 tu moi nguon
export sg_modification_status=$(aws ec2 authorize-security-group-ingress --group-id $security_group_id --protocol tcp --port 8888 --cidr 0.0.0.0/0 --query 'Return' --output text)

echo "Security group modified properly: $sg_modification_status"

# Cai dat Terraform
sudo yum install -y yum-utils  # Cai dat yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo  # Them repository HashiCorp
sudo yum -y install terraform  # Cai dat Terraform

echo "Terraform has been installed"

# Dinh nghia cac bien Terraform
echo "export TF_VAR_project=$de_project" >> $HOME/.bashrc  # Du an
echo "export TF_VAR_region=$AWS_DEFAULT_REGION" >> $HOME/.bashrc  # Vung
echo "export TF_VAR_vpc_id=$VPC_ID" >> $HOME/.bashrc  # VPC ID
echo "export TF_VAR_private_subnet_a_id=$(aws ec2 describe-subnets --filters "Name=tag:aws:cloudformation:logical-id,Values=PrivateSubnetA" "Name=vpc-id,Values=$VPC_ID" --output text --query "Subnets[].SubnetId")" >> $HOME/.bashrc  # ID subnet rieng
echo "export TF_VAR_db_sg_id=$(aws rds describe-db-instances --db-instance-identifier de-c1w2-rds --output text --query "DBInstances[].VpcSecurityGroups[].VpcSecurityGroupId")" >> $HOME/.bashrc  # ID security group cho RDS
echo "export TF_VAR_host=$(aws rds describe-db-instances --db-instance-identifier de-c1w2-rds --output text --query "DBInstances[].Endpoint.Address")" >> $HOME/.bashrc  # Dia chi endpoint cua RDS
echo "export TF_VAR_port=3306" >> $HOME/.bashrc  # Cong co so du lieu
echo "export TF_VAR_database=\"classicmodels\"" >> $HOME/.bashrc  # Ten co so du lieu
echo "export TF_VAR_username=\"admin\"" >> $HOME/.bashrc  # Ten nguoi dung
echo "export TF_VAR_password=\"adminpwrd\"" >> $HOME/.bashrc  # Mat khau

# Tai lai cac bien moi truong
source $HOME/.bashrc

# Thay the ten bucket trong file backend.tf
script_dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")  # Lay thu muc cua script
sed -i "s/<terraform_state_bucket>/\"de-c1w2-$(aws sts get-caller-identity --query 'Account' --output text)-us-east-1-terraform-state\"/g" "$script_dir/../infrastructure/terraform/backend.tf"

# Cai dat Docker
sudo yum update -y  # Cap nhat he thong
sudo yum install docker -y  # Cai dat Docker
sudo service docker start  # Khoi dong dich vu Docker
sudo usermod -a -G docker $USER  # Them nguoi dung vao nhom Docker
# newgrp docker  # Khoi dong lai shell voi quyen Docker
docker build -t jupyterlab-image $(pwd)/infrastructure/jupyterlab > docker_output.txt  # Xay dung hinh anh Docker cho Jupyter Lab
docker run -d -it -p 8888:8888 jupyterlab-image  # Chay container Docker

echo "Jupyter lab deployed"

sleep 25  # Cho mot thoi gian de container khoi dong

# Lay ID cua container Jupyter Lab de trich xuat log
CONTAINER_ID=$(docker ps -a --filter "ancestor=jupyterlab-image" --format "{{.ID}}")

# echo "Container id $CONTAINER_ID"  # In ra ID cua container

# Trich xuat URL tu log cua container
jupyter_url_local=$(docker logs $CONTAINER_ID | grep -oP 'http://127.0.0.1:\d+/lab\?token=[a-f0-9]+' | head -1)

echo "jupyter url local $jupyter_url_local"  # In ra URL cuc bo cua Jupyter Lab

# Lay ten DNS cong cong cua EC2 instance
ec2_dns=$(ec2-metadata --public-hostname | grep -o ec2-.*)
echo "jupyter url local $ec2_dns"

# Thay the DNS trong URL
jupyter_url=$(echo "$jupyter_url_local" | sed "s/127.0.0.1/${ec2_dns}/")

# In ra URL cap nhat
echo "Jupyter is running at: $jupyter_url" >> jupyter_output.log  # Ghi vao file log
echo "Jupyter is running at: $jupyter_url"  # In ra URL
