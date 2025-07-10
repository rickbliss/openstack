#!/bin/bash

# GitHub Issues to Local Markdown Sync Script
# Requires: gh CLI tool (https://cli.github.com/)

set -euo pipefail

# Configuration
REPO="rickbliss/openstack"
OUTPUT_DIR="docs/issues"
BACKLOG_FILE="docs/BACKLOG.md"
SUMMARY_FILE="docs/ISSUE_SUMMARY.md"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_section() {
    echo -e "${BLUE}[SYNC]${NC} $1"
}

# Create output directory
mkdir -p "$OUTPUT_DIR"

print_status "Starting GitHub Issues sync for repository: $REPO"

# Function to sync individual issues
sync_issues() {
    local state=$1
    local label_filter=$2
    
    print_section "Syncing $state issues..."
    
    # Get issues based on state and optional label
    if [[ -n "$label_filter" ]]; then
        issues=$(gh issue list --repo "$REPO" --state "$state" --label "$label_filter" --json number,title,state,labels,assignees,createdAt,updatedAt,body,url)
    else
        issues=$(gh issue list --repo "$REPO" --state "$state" --json number,title,state,labels,assignees,createdAt,updatedAt,body,url)
    fi
    
    # Convert to individual markdown files
    echo "$issues" | jq -r '.[] | @base64' | while read -r issue; do
        issue_data=$(echo "$issue" | base64 --decode)
        
        number=$(echo "$issue_data" | jq -r '.number')
        title=$(echo "$issue_data" | jq -r '.title')
        state=$(echo "$issue_data" | jq -r '.state')
        body=$(echo "$issue_data" | jq -r '.body // "No description provided"')
        url=$(echo "$issue_data" | jq -r '.url')
        created=$(echo "$issue_data" | jq -r '.createdAt')
        updated=$(echo "$issue_data" | jq -r '.updatedAt')
        
        # Get labels
        labels=$(echo "$issue_data" | jq -r '.labels[]?.name // empty' | tr '\n' ',' | sed 's/,$//')
        
        # Get assignees
        assignees=$(echo "$issue_data" | jq -r '.assignees[]?.login // empty' | tr '\n' ',' | sed 's/,$//')
        
        # Clean title for filename
        safe_title=$(echo "$title" | tr '/' '-' | tr ' ' '_' | tr -cd '[:alnum:]_-')
        filename="${OUTPUT_DIR}/issue_${number}_${safe_title}.md"
        
        # Create markdown file
        cat > "$filename" << EOF
# Issue #${number}: ${title}

**Status:** ${state}  
**Created:** ${created}  
**Updated:** ${updated}  
**URL:** ${url}

**Labels:** ${labels:-none}  
**Assignees:** ${assignees:-unassigned}

---

## Description

${body}

---

*Last synced: $(date)*
*Source: GitHub Issues API*
EOF
        
        echo "  ✓ Synced issue #$number: $title"
    done
}

# Function to create backlog summary
create_backlog() {
    print_section "Creating backlog summary..."
    
    cat > "$BACKLOG_FILE" << 'EOF'
# Project Backlog

*Auto-generated from GitHub Issues*

## 🔥 Critical Issues (P0)
EOF
    
    # Add critical issues
    gh issue list --repo "$REPO" --state open --label "priority/critical" --json number,title,labels,assignees | \
    jq -r '.[] | "- [#\(.number)](\(.url)) \(.title) - **Assignee:** \(.assignees[0]?.login // "unassigned")"' >> "$BACKLOG_FILE"
    
    cat >> "$BACKLOG_FILE" << 'EOF'

## 🚨 High Priority (P1)
EOF
    
    # Add high priority issues
    gh issue list --repo "$REPO" --state open --label "priority/high" --json number,title,url,assignees | \
    jq -r '.[] | "- [#\(.number)](\(.url)) \(.title) - **Assignee:** \(.assignees[0]?.login // "unassigned")"' >> "$BACKLOG_FILE"
    
    cat >> "$BACKLOG_FILE" << 'EOF'

## 📋 Medium Priority (P2)
EOF
    
    # Add medium priority issues
    gh issue list --repo "$REPO" --state open --label "priority/medium" --json number,title,url,assignees | \
    jq -r '.[] | "- [#\(.number)](\(.url)) \(.title) - **Assignee:** \(.assignees[0]?.login // "unassigned")"' >> "$BACKLOG_FILE"
    
    cat >> "$BACKLOG_FILE" << 'EOF'

## 🔧 Component Breakdown

### Deployment Issues
EOF
    
    # Add by component
    gh issue list --repo "$REPO" --state open --label "component/deployment" --json number,title,url | \
    jq -r '.[] | "- [#\(.number)](\(.url)) \(.title)"' >> "$BACKLOG_FILE"
    
    cat >> "$BACKLOG_FILE" << 'EOF'

### Networking Issues
EOF
    
    gh issue list --repo "$REPO" --state open --label "component/networking" --json number,title,url | \
    jq -r '.[] | "- [#\(.number)](\(.url)) \(.title)"' >> "$BACKLOG_FILE"
    
    cat >> "$BACKLOG_FILE" << 'EOF'

### Storage Issues
EOF
    
    gh issue list --repo "$REPO" --state open --label "component/storage" --json number,title,url | \
    jq -r '.[] | "- [#\(.number)](\(.url)) \(.title)"' >> "$BACKLOG_FILE"
    
    cat >> "$BACKLOG_FILE" << EOF

---

## Summary Statistics

**Total Open Issues:** $(gh issue list --repo "$REPO" --state open --json number | jq length)  
**Critical Issues:** $(gh issue list --repo "$REPO" --state open --label "priority/critical" --json number | jq length)  
**High Priority:** $(gh issue list --repo "$REPO" --state open --label "priority/high" --json number | jq length)  

**Last Updated:** $(date)

---

*This backlog is automatically generated from GitHub Issues*  
*Run \`./sync_issues.sh\` to update*
EOF
}

# Function to create issue summary
create_summary() {
    print_section "Creating issue summary..."
    
    cat > "$SUMMARY_FILE" << EOF
# Issue Summary Dashboard

*Last Updated: $(date)*

## Quick Stats

| Metric | Count |
|--------|-------|
| Open Issues | $(gh issue list --repo "$REPO" --state open --json number | jq length) |
| Closed Issues | $(gh issue list --repo "$REPO" --state closed --json number | jq length) |
| Critical (P0) | $(gh issue list --repo "$REPO" --state open --label "priority/critical" --json number | jq length) |
| High Priority (P1) | $(gh issue list --repo "$REPO" --state open --label "priority/high" --json number | jq length) |

## Component Breakdown

| Component | Open Issues |
|-----------|-------------|
| Deployment | $(gh issue list --repo "$REPO" --state open --label "component/deployment" --json number | jq length) |
| Networking | $(gh issue list --repo "$REPO" --state open --label "component/networking" --json number | jq length) |
| Storage | $(gh issue list --repo "$REPO" --state open --label "component/storage" --json number | jq length) |
| Compute | $(gh issue list --repo "$REPO" --state open --label "component/compute" --json number | jq length) |
| Identity | $(gh issue list --repo "$REPO" --state open --label "component/identity" --json number | jq length) |
| Dashboard | $(gh issue list --repo "$REPO" --state open --label "component/dashboard" --json number | jq length) |
| Load Balancer | $(gh issue list --repo "$REPO" --state open --label "component/load-balancer" --json number | jq length) |

## Recent Activity

### Recently Created (Last 7 days)
EOF
    
    # Add recent issues
    gh issue list --repo "$REPO" --state all --limit 20 --json number,title,state,createdAt,url | \
    jq --arg week_ago "$(date -d '7 days ago' --iso-8601)" \
    '.[] | select(.createdAt > $week_ago) | "- [#\(.number)](\(.url)) \(.title) (\(.state))"' -r >> "$SUMMARY_FILE"
    
    cat >> "$SUMMARY_FILE" << EOF

### Recently Updated (Last 3 days)
EOF
    
    # Add recently updated
    gh issue list --repo "$REPO" --state all --limit 20 --json number,title,state,updatedAt,url | \
    jq --arg three_days_ago "$(date -d '3 days ago' --iso-8601)" \
    '.[] | select(.updatedAt > $three_days_ago) | "- [#\(.number)](\(.url)) \(.title) (\(.state))"' -r >> "$SUMMARY_FILE"
    
    echo "" >> "$SUMMARY_FILE"
    echo "---" >> "$SUMMARY_FILE"
    echo "" >> "$SUMMARY_FILE"
    echo "*Auto-generated by sync_issues.sh*" >> "$SUMMARY_FILE"
}

# Main execution
main() {
    # Check if gh CLI is installed
    if ! command -v gh &> /dev/null; then
        echo "❌ GitHub CLI (gh) is not installed. Please install it first:"
        echo "   https://cli.github.com/"
        exit 1
    fi
    
    # Check if logged in
    if ! gh auth status &> /dev/null; then
        echo "❌ Not logged in to GitHub CLI. Please run: gh auth login"
        exit 1
    fi
    
    # Sync different types of issues
    sync_issues "open" ""
    sync_issues "closed" ""
    
    # Create backlog and summary
    create_backlog
    create_summary
    
    print_status "✅ Sync completed successfully!"
    print_status "📁 Issues synced to: $OUTPUT_DIR"
    print_status "📋 Backlog created: $BACKLOG_FILE"
    print_status "📊 Summary created: $SUMMARY_FILE"
    
    # Show quick summary
    echo ""
    echo "📊 Quick Summary:"
    echo "   Open Issues: $(gh issue list --repo "$REPO" --state open --json number | jq length)"
    echo "   Closed Issues: $(gh issue list --repo "$REPO" --state closed --json number | jq length)"
    echo "   Total Files Created: $(find "$OUTPUT_DIR" -name "*.md" | wc -l)"
}

# Run main function
main "$@"